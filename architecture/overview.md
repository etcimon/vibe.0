# Overview — request journey

Pin: `eb51b27` / `v1.2.1`. This is how a typical HTTPS server in this fork actually runs. The README’s sample `app.d` is the intended consumer shape.

## 0. Process start (before any listen)

1. The application imports `vibe.d` **or** `vibe.vibe` plus the modules it needs. `import vibe.d;` does **not** give you a working `main()` in this fork (see [build-test.md](build-test.md)).
2. `vibe.core.core` `shared static this()` (process):
   - Initializes the log module.
   - Allocates `VibeDriverCore` (`s_core`) and the thread registry mutex/condition.
   - Installs SIGINT/SIGTERM/SIGPIPE (POSIX) or SIGABRT/SIGTERM/SIGINT (Windows).
   - Names the main thread `"V|Main"`. Threads whose name does not start with `"V|"` are ignored by later per-thread setup.
   - Calls `setupDriver()` → `setupEventDriver(s_core)` → `new LibasyncDriver(core)`.
   - Creates a process-wide `ManualEvent` used as a cross-thread wake (`st_threadsSignal`).
   - Optionally registers `--uid`/`--gid` CLI options (unless `VibeNoDefaultArgs`).
   - If `newStdConcurrency`, installs `VibedScheduler` into `std.concurrency`.
3. Per `"V|…"` thread, `static this()` allocates a `CoreTask` fiber slot and calls `setupDriver()` again so worker threads get their own `LibasyncDriver` / `EventLoop`.
4. Consumer `main()` builds settings, registers routes, calls `listenHTTP`, then **must** call `runEventLoop()`.

`vibeVersionString` is still `"0.7.23"` (the upstream vibe.d tag at the 2015 fork). The git tag of *this* repo is `v1.2.1`. Do not conflate them.

## 1. `listenHTTP(settings, handler)`

Locus: `source/vibe/http/server.d`.

- Enforces at least one `bindAddresses` entry. Default is `["::", "0.0.0.0"]`.
- **Thread invariant:** listening may only happen on the thread that first called `listenHTTP` (`g_ctor`). “Listening from multiple threads is unsupported.”
- Allocates an `HTTPServerContext` in `ThreadMem`: settings + `requestHandler` + optional access loggers. Pushed onto `g_contexts`.
- If `settings.tlsContext` is set:
  - Stores the context pointer as TLS user-data (SNI / virtual-host lookup later).
  - Installs an ALPN chooser unless the context already has one:
    - `disableHTTP2` → always `"http/1.1"`.
    - else prefer `"h2"`, `"h2-16"`, `"h2-14"`, then `"http/1.1"`.
- Calls `listenHTTPPlain`.

`listenHTTPPlain` walks each bind address:

- If a `HTTPServerListener` already exists for `(addr, port)`, it is treated as a **virtual host** (`addVHost`). Multiple `hostName`s on the same socket share one listen fd. Overlapping TLS contexts without SNI is asserted against; SNI builds a `TLSContextKind.serverSNI` wrapper whose callback searches `g_contexts` by hostname.
- Otherwise `listenTCP(port, conn => handleHTTPConnection(conn, listener), addr, options)` via `vibe.core.net`. `TCPListenOptions.distribute` is set if `HTTPServerOption.distribute` is on (worker-thread handoff; lightly read). `tcpNoDelay` is optional.

`vibe.http.dist` (`listenHTTPDist`) is compiled out (`version(none)`). The comment on `listenHTTP` about `--disthost` / VibeDist is leftover.

## 2. TCP accept → one fiber per connection

Locus: `source/vibe/core/net.d` → `source/vibe/core/drivers/libasync.d`.

`listenTCP` is a thin wrapper over `getEventDriver().listenTCP(...)`. The libasync driver binds an `AsyncTCPListener`. On `TCPEvent.CONNECT` for an inbound socket it `runTask(&onConnect)`. `onConnect` calls the user callback (`handleHTTPConnection`) and, for inbound sockets, `close()`s when the callback returns.

So: **one `Task` (fiber) per accepted TCP connection.** That fiber owns the whole HTTP/1.1 keep-alive loop, or the whole HTTP/2 session (which then multiplexes streams as further tasks — see [http.md](http.md)).

`runTask` (`vibe.core.core`) either recycles a `CoreTask` from `s_availableFibers` or `ThreadMem.alloc!CoreTask`. It resumes the fiber synchronously so the task runs until the first yield (typically the first socket read).

## 3. `handleHTTPConnection(tcp, listen_info)`

Locus: `server.d` ~1748.

```
waitForData(10s)                         — else 408 + close
if tlsContext:
    peek ClientHello (0x16 0x03 … 0x01)  — else 497 "HTTP to HTTPS"
    tls_stream = createTLSStream(tcp, ctx, accepting, …)
    chosen_alpn = tls_stream.alpn
    if vhosts: context = tls user-data (SNI-selected)
http2 = new HTTP2HandlerContext(...)
if http2.tryStart(chosen_alpn): return   — HTTP/2 session ate the connection
loop:                                    — HTTP/1.1 / 1.0 keep-alive
    handleRequest(..., keep_alive)
    if h2c upgrade: continueHTTP2Upgrade(); return
    if !keep_alive: break
    waitForData(keepAliveTimeout)
```

`tryStart`:

- Cleartext: if the first 24 bytes are `PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`, start a prior-knowledge HTTP/2 session (`startHTTP2`) and block in `HTTP2Session.run()`.
- TLS: if ALPN starts with `"h2"` and HTTP/2 is not disabled, `startTLSHTTP2` and block in `session.run()`.

Otherwise the connection stays HTTP/1.x. Mid-loop, `tryStartUpgrade` looks for `Upgrade: h2c` + `HTTP2-Settings` and, if so, writes `101 Switching Protocols` and runs the HTTP/2 session in a **new** task so stream 1 can finish as HTTP/2 while the original `handleRequest` is still on the stack.

## 4. `handleRequest` — parse, decorate, dispatch

Locus: `server.d` ~1888.

Per request it allocates `HTTPServerRequest` / `HTTPServerResponse` from `ThreadMem` and a 4 KiB `ScopedPool` for parser scratch.

**Top stream** (read/write target), in priority order: `HTTP2Stream` if present, else `TLSStream`, else raw `TCPConnection`.

Parse path:

| Kind | Header parse | Host / vhost |
|------|--------------|--------------|
| HTTP/1.x | `parseRequestHeader` with `maxRequestHeaderSize` | `Host` required; if vhosts, `getServerContext(authority)` |
| HTTP/2 | `parseHTTP2RequestHeader` from the stream | same Host check; must match the session context |

Body is **lazy** (`BodyReader`): `Content-Length` → `LimitedHTTPInputStream`; `Transfer-Encoding: chunked` → `ChunkedInputStream` then limited; optional `TimeoutHTTPInputStream` if `maxRequestTime` is set. Most handlers never touch it.

Then, driven by `HTTPServerOption` bits (defaults = parse URL, query, form, JSON, multipart, cookies, **and** `errorStackTraces`):

- Optional gzip/deflate `Content-Encoding` on the response if `useCompressionIfPossible` and `Accept-Encoding` matches (brotli is **not** selected here; see [data-db.md](data-db.md)).
- `Expect: 100-continue` → write `100 Continue` on the top stream (HTTP/1.1 phrasing even under TLS).
- Session cookie → `sessionStore.open`.
- Form / JSON body parse **drains** `bodyReader` when those options are on.

Default response headers: `Server` (`"vibe.d/" ~ vibeVersionString` unless overridden), cached `Date`, `Keep-Alive` for persistent HTTP/1.1.

**Dispatch:** `context.requestHandler(req, res)` inside `scoped_pool.freeze()`. For a `URLRouter` this is `URLRouter.handleRequest`.

If nothing wrote headers (`res.headerWritten`, or for HTTP/2 `!http2_stream.headersWritten`), the server synthesizes **404**. Exceptions become 4xx/5xx via `errorPageHandler` or a plain-text dump that includes `TaskDebugger` breadcrumbs / call stack when debug versions are on.

Keep-alive is `req.persistent` unless an error justified closing.

## 5. `URLRouter`

Locus: `source/vibe/http/router.d`.

`URLRouter` implements `HTTPRouter` / `HTTPServerRequestHandler`. Routes are registered with `match` / `get` / `post` / `put` / `delete_` / `patch` / `any`.

Match language (interface, not just docs):

- Literal path segments.
- `:name` placeholders — one path segment, stored in `req.params["name"]`.
- Trailing `*` raw wildcard.
- Max 64 placeholders. At least one character between placeholders.

Default implementation is the **tree matcher** (`version = VibeRouterTreeMatch` unless `VibeOldRouterImpl`). `rebuild()` forces eager graph construction; otherwise the first request pays for it.

Matching walks in registration order. A handler “wins” when it writes response headers. `HEAD` falls back to `GET`. No match → return without writing → server 404.

`registerWebInterface` (`vibe.web.web`) is a codegen layer on top: public methods of a class become routes, parameters come from query/form/`req.params`, `@before`/`@after`/`@path`/`@method` UDAs apply. This is how the README’s `UserAPI` / `InstallationAPI` attach.

## 6. Response write-back

`HTTPServerResponse` writes to the same top stream. HTTP/1.1 may chunk; HTTP/2 writes DATA frames through `HTTP2Stream`. Compression wrappers (`vibe.stream.zlib`) sit on the body writer when `Content-Encoding` was set. `finalize()` flushes and, for HTTP/2, ends the stream.

The connection fiber then either loops (HTTP/1.1 keep-alive), joins the h2c upgrade task, or returns — libasync then closes an inbound socket.

## 7. Event loop around all of this

`runEventLoop()` (`vibe.core.core`):

- Sets `s_eventLoopRunning`, notifies idle (runs already-yielded tasks), starts `watchExitFlag` on the main thread.
- Delegates to `LibasyncDriver.runEventLoop()`:
  ```
  while (!exitFlag && getEventLoop().loop(-1.seconds)) {
      processTimers();
      getDriverCore().notifyIdle();
  }
  ```
- libasync `EventLoop.loop` is the OS wait (IOCP / epoll / kqueue, depending on the libasync build). Socket readiness resumes the waiting fiber via `DriverCore.resumeTask`.
- Exit: `exitEventLoop()` triggers an `AsyncSignal`; Windows also ORs `getExitFlag` (service-friendly). Process teardown waits for non-daemon `"V|…"` threads and logs leftover connections / HTTP/2 sessions / streams.

## Sequence (compressed)

```
main()
  listenHTTP(settings, router)
    listenTCP(port, handleHTTPConnection, addr)
  runEventLoop()
    LibasyncDriver.loop
      TCP accept → runTask(handleHTTPConnection)
        [TLS accept + ALPN]
        HTTP2Session.run  ──or──  HTTP/1.1 loop
          handleRequest
            parse headers / lazy body / cookies / session
            router.handleRequest
              route.cb  or  web-interface generated handler
            write response / 404 / error page
```

## What this journey is not

- **Not** official vibe.d’s libevent driver path. There is no `VibeLibeventDriver` implementation in this tree; remnants exist only as `version` branches (e.g. WinSock init, timer stubs in `sync.d`).
- **Not** Diet / `vibe.templ`. Gone.
- **Not** `vibe.web.rest`. `vibe.web.common` still talks about REST; the generator module is not here.
- **Not** a verified green run. The journey above is source-traced, not executed on this host.
