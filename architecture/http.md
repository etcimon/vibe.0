# HTTP (1.x, 2, router, client, extras)

Pin: `eb51b27` / `v1.2.1`. Loci: `source/vibe/http/server.d` (~2.0k), `http2.d` (~2.3k), `client.d` (~1.5k), `router.d` (~840), `websockets.d` (~1.0k), plus `common`, `status`, `session`, `fileserver`, `form`, `proxy`, `cookiejar`, `auth/*`, `debugger`, `log`, `dist`.

The request journey is in [overview.md](overview.md). This file is the module map and the HTTP/2 / client / side-path details.

## Common types (`http.common`, `http.status`)

- `HTTPVersion`: `HTTP_1_0`, `HTTP_1_1`, `HTTP_2`.
- `HTTPMethod`: standard verbs + WebDAV (`COPY`, `LOCK`, `MKCOL`, `MOVE`, `PROPFIND`, `PROPPATCH`, `UNLOCK`, `REPORT`).
- `HTTPRequest` / `HTTPResponse`: version, method, URL, `InetHeaderMap`.
- `HTTPStatus` + `httpStatusText` + `HTTPStatusException`.
- `enforceHTTP` / `enforceBadRequest` — the server parse path uses these heavily.
- HTTP/2 and TLS stream types are imported here so common code can talk to either transport.

## Server

### Settings that matter

`HTTPServerSettings` (class):

| Field | Default / note |
|-------|----------------|
| `port` | 80 |
| `bindAddresses` | `["::", "0.0.0.0"]` |
| `hostName` | virtual-host key |
| `options` | `HTTPServerOption.defaults` (parse everything + error stack traces; **not** `distribute`) |
| `keepAliveTimeout` | 10 seconds |
| `maxRequestSize` | 2 MiB |
| `maxRequestHeaderSize` | 8 KiB |
| `tlsContext` | null → plaintext; `sslContext` is a property alias |
| `sessionStore` / `sessionIdCookie` | cookie sessions |
| `serverString` | `"vibe.d/" ~ vibeVersionString` → `"vibe.d/0.7.23"` |
| `disableHTTP2` | false |
| `http2Settings` | `HTTP2Settings` (push, windows, frame size, max streams) |
| `useCompressionIfPossible` | **true** (gzip/deflate via `Accept-Encoding`; not brotli) |
| `tcpNoDelay` | false |
| `webSocketPingInterval` | 60 seconds |
| `disableDistHost` | leftover; dist module is `version(none)` |
| `errorPageHandler` | custom error pages |
| `accessLog*` | Apache-format file/console loggers |

`HTTPServerOption.distribute` is the only default-off performance knob besides disabling parsers. Stack traces on errors are **on by default** — README’s production snippet xors them off.

### Connection + request

Covered in [overview.md](overview.md). Extra loci:

- `HTTPServerContext`: per-`listenHTTP` settings + handler + loggers. Looked up by `(bind, port)` or by `Host` when `vhosts > 0`.
- `HTTPServerListener`: one real socket; `vhosts` counter; optional SNI TLS wrapper.
- `HTTPServerRequest`: peer address, `path` / `query` / `form` / `json` / `cookies` / `params` / `files` / `session` / `tls` / `clientCertificate` / lazy `bodyReader`.
- `HTTPServerResponse`: `writeBody`, `writeJsonBody`, `writeRawBody`, `bodyWriter`, `startSession`, header map, HTTP/2 vs 1.x finalize.

Initial wait for the first bytes is **hard-coded 10 seconds** (not `keepAliveTimeout`). Wrong-protocol-on-TLS-port is a hardcoded 497 page.

### HTTP/2 on the server (`HTTP2HandlerContext`)

Three start modes:

1. **Prior knowledge, cleartext** — preface `PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`.
2. **ALPN `h2*` over TLS** — `startTLSHTTP2`.
3. **h2c upgrade** — `Upgrade: h2c` + `Connection: Upgrade, HTTP2-Settings` + `HTTP2-Settings` (base64). Responds `101`, runs `session.run(true)` in a new task, returns stream 1 to the in-flight `handleRequest`.

`HTTP2Session` (`http2.d`) wraps `libhttp2.session.Session` plus a `HTTP2Connector`. It owns read/write loops (`ReadLoop` / `WriteLoop`) as tasks, a dirty-stream list, push-response list, and ping/pong slots.

`HTTP2Stream` is a `ConnectionStream` + `CountedStream`:

- Stream id `-1` until assigned; server streams always `> 0`.
- Separate `Incoming` / `Outgoing` buffer state, pause flags, priority spec.
- `SafetyLevel` `{None, ZeroizeBuffers, LockMemory}` — default `LockMemory` when TLS is on, dropped to `None` on first read unless the user set it (comment in file).
- `StreamExitException` if the peer resets/closes early.

`HTTP2Settings` (this fork, not the RFC struct only):

- `enablePush`
- `connectionWindowSize` / `streamWindowSize`
- `chunkSize` (max frame / 16 KiB default)
- `maxConcurrentStreams`
- `maxHeadersListSize`
- Packs to a SETTINGS payload / `toBase64Settings()` for the upgrade header.

Each accepted HTTP/2 request becomes `handler(HTTP2Stream)` → `handleRequest(..., http2_stream, ...)` so the rest of the server (router, sessions, compression) is protocol-agnostic after header parse.

`parseHTTP2RequestHeader` maps `:method`, `:path`, `:authority`, `:scheme` onto `HTTPRequest` / `Host`.

Global counters: `s_totalSessions`, `s_totalStreams`, `s_http2Registry` (URI + last activity) — dumped at process exit and by `vibe.http.debugger`.

**Unread:** frame-level connector callbacks, push-promise path, priority, flow-control edge cases, client-side session in the same file (~second half of `http2.d`).

## Router

`HTTPRouter` interface is marked for removal in the module comment (match syntax is the real interface). `URLRouter` is the implementation.

Tree match (`MatchTree!Route`) is default. `VibeOldRouterImpl` keeps a linear array. `rebuild()` precomputes the graph.

Nested routers / prefix: constructor `this(string prefix)`. `registerWebInterface` builds paths from method names (`MethodStyle.lowerUnderscored` default) and `@path`.

HEAD→GET fallback is in the router, not the server.

## Client (`http.client`)

Public entry: `requestHTTP(url, requester, responder, settings)` and `connectHTTP` (pooled).

`HTTPClientSettings`:

- `proxyURL`
- `defaultKeepAliveTimeout` (115s)
- `maxRedirects` (2)
- `userAgent` (default `"vibe.d/0.7.23 (HTTPClient, +http://vibed.org/)"`)
- `cookieJar` (`CookieStore`)
- nested `http2`: `forced`, `disable`, `disablePlainUpgrade` (**true** by default — h2c upgrade off unless flipped), `pingInterval`, `maxInactivity`, `HTTP2Settings`, ALPN list `["h2","h2-14","h2-16","http/1.1"]`
- `tlsContext` override

Pooling: thread-local `CircularBuffer` of 16 `(ConnInfo, ConnectionPool!HTTPClient)`. `ConnInfo` is `(host, port, settings)` — **settings identity** (reference), so cloned settings make a new pool. HTTP/2: after the preface, `lockConnection()` returns a child client multiplexed on the same TCP (`master` flag). Dtor disconnects; GC/`g_exiting` path is special-cased (`gc_inFinalizer`).

Client HTTP/2: ALPN or forced preface; optional cleartext upgrade if `disablePlainUpgrade` is cleared. `examples/h2_request` is the living sample (httpbin, cookie jar, ping).

Body decode: gzip/deflate (`vibe.stream.zlib`) and **brotli** (`vibe.stream.brotli`) on the client — server auto-encode does not offer brotli.

**Unread:** full redirect loop, proxy CONNECT, HTTP/2 client stream allocation, `HTTPClientResponse` lifetime warnings.

## WebSockets

`handleWebSockets` / `handleWebSocket`: upgrade from HTTP/1.1 (and, unverified, HTTP/2). Ping interval from server settings. Client helper exists (imports `http.client`). `examples/websocket` + `public/scripts/websocket.js`.

~1k lines, **sampled only** (module header + server settings field).

## Reverse proxy

`listenHTTPReverseProxy` / `reverseProxyRequest`. Forces `HTTPServerOption.none` on the outer server (no body parse). Forwards most headers except hop-by-hop (`te`, `Content-Length`, `Transfer-Encoding`, `Content-Encoding`, `Connection`). Can proxy WebSockets. Settings include destination host/port/IP, `secure`, and a nested `HTTPClientSettings` (README uses this to disable HTTP/2 toward a Vite dev server).

File header TODOs: client pool, path-based proxy, forward proxy — **still open**.

## Fileserver

`serveStaticFiles` / `serveStaticFile`. Prefix strip, `Path.normalize`, reject absolute and `..`. Optional `encodingFileExtension` (static server example maps `"gzip" → ".gz"` so precompressed files are served with `Content-Encoding`). MIME from `vibe.inet.mimetypes`. Directory `index.html` was an upstream 0.7.23 feature; **not re-verified** in this fork’s `sendFile`.

## Sessions

`Session` + `SessionStore` interface. Cookie name from settings. ID from `SHA1HashMixerRNG` (`crypto.cryptorand`) — constructed only on `"V|"` threads.

Implementations in-tree:

- Memory store (in `session.d` — lightly read)
- `vibe.db.redis.sessionstore.RedisSessionStore` (JSON values, optional TTL)

## Auth

- `http.auth.basic_auth`: `performBasicAuth(realm, pwcheck)` — `Authorization: Basic`.
- `http.auth.digest_auth`: digest (upstream 0.7.23 addition). **Not in the barrel.** Lightly unread.

## Cookies (client)

`http.cookiejar` + `cookiejar_dates.d` (BSD-3). `FileCookieJar` used by `h2_request`. Server cookies are the simple `Cookie` map on req/res, not this jar.

## Debugger / access log / dist

- `http.debugger`: allocation + task dump handlers. Compiled out under `VibeNoDebug`.
- `http.log`: Apache combined format; attached in `listenHTTP` if configured.
- `http.dist`: **entire module `version(none)`**. VibeDist load balancer is dead code kept for archaeology.

## Web interface (sits on HTTP, lives in `vibe.web`)

`registerWebInterface` maps class methods to routes. Parameter rules (query/form/`_prefixed` → `req.params`) and UDAs (`@before`, `@after`, `@path`, `@method`, `@errorDisplay`, `@contentType`) are the consumer API for the README’s `UserAPI`. `SessionVar!(T, "key")` binds session keys. There is **no** `vibe.web.rest` in this tree; `web.common` still mentions REST in its header.

## Inet helpers HTTP leans on

`vibe.inet.message` (header maps, RFC 822 dates), `url` / `path`, `webform` (form + multipart), `mimetypes`, `urltransfer` (`download` example). Not HTTP-specific but on the request path.

## Invariants

- One listen thread (`g_ctor`). Do not `listenHTTP` from workers.
- Protocol switch happens **before** the user handler, except h2c upgrade which splits stream 1.
- Writing headers commits the route. Fall-through is silent; the server 404s only if **nothing** wrote.
- Default options parse and drain form/JSON bodies. Handlers that need the raw stream must clear those bits.
- Client HTTP/2 cleartext upgrade is **off** by default; server h2c upgrade is **on** if HTTP/2 is enabled.
- `serverString` / UA still say `vibe.d/0.7.23`.

## Unread

- Majority of `http2.d` (connector, push, client session, ping internals).
- `HTTPServerResponse` write/chunk/HTTP2 frame emission.
- `parseRequestHeader` / cookie parser / form parser bodies.
- WebSocket frame state machine.
- Digest auth, cookie jar eviction, fileserver `sendFile`, access-log format tokens.
- `http.test.d` unittest harness.
