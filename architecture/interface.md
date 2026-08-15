# Interface — public `vibe.*` vs internals

Pin: `eb51b27` / `v1.2.1`. DUB name **`vibe-0`**, `targetType: library`.

## Two barrels, one product

| Module | File | Intended use |
|--------|------|----------------|
| `vibe.d` | `source/vibe/d.d` | Historical “import everything + implicit main”. **main is dead** (see [build-test.md](build-test.md)). |
| `vibe.vibe` | `source/vibe/vibe.d` | Same public re-exports, no implicit main. README still says to import this when you supply `VibeCustomMain`. |

The two files are the same import list. Typical apps should import **narrower** modules (`vibe.core.core`, `vibe.http.server`, …) plus `vibe.d` only if they want the grab-bag.

`dub.json` `"mainSourceFile": "source/vibe/appmain.d"` pulls `vibe.appmain` into the library. That module’s `main()` is compiled only when `VibeDefaultMain` is set **and** `VibeCustomMain` is not. When compiled, it `static assert`s. Consumers are expected to define `VibeCustomMain` and write `main()`.

## Barrel re-exports (`vibe.d` / `vibe.vibe`)

**In:**

- Core: `args`, `concurrency`, `core`, `file`, `log`, `net`, `sync`, `trace`
- Crypto: `passwordhash` only (not `cryptorand`)
- Data: `json` (which public-imports `serialization`)
- DB: `redis.redis` only
- HTTP: `auth.basic_auth`, `client`, `fileserver`, `form`, `proxy`, `router`, `server`, `debugger`, `websockets`
- Inet: `message`, `url`, `urltransfer`
- Mail: `smtp`
- Stream: `counting`, `memory`, `operations`, `ssl` (compat shim over `tls`), `zlib`
- Textfilter: `html`, `urlencode`
- Utils: `string`
- Web: `web`

Plus Phobos: `std.functional.toDelegate`, `std.conv.to`, `std.datetime`, `std.exception.enforce`.

**Not in the barrel** (still importable as `vibe.*` — these are public modules, just not starred):

| Area | Modules |
|------|---------|
| HTTP | `http.common`, `http.status`, `http.session`, `http.http2`, `http.cookiejar`, `http.dist` (`version(none)`), `http.log`, `http.test` (`version(unittest)`), `http.auth.digest_auth` |
| Stream | `stream.tls` (prefer this over `ssl`), `stream.botan`, `stream.openssl`, `stream.brotli`, `stream.base64` (commented out of barrel), `stream.bufcomp`, `stream.multicast`, `stream.stdio`, `stream.taskpipe`, `stream.wrapper` |
| Data | `data.xml`, `data.dom`, `data.brotli` |
| DB | `db.sqlite.sqlite3`, `db.pgsql.pgsql`, `db.redis.idioms`, `db.redis.sessionstore`, `db.redis.types` |
| Core | `core.driver` (imported by `core.core`), `core.task`, `core.connectionpool`, `core.stream` |
| Other | `crypto.cryptorand`, `daemonize.*`, `inet.path`, `inet.mimetypes`, `inet.webform`, `web.common`, `web.validation`, `utils.array`, `utils.memory`, `utils.validation` |

README sample code imports several of these non-barrel modules explicitly (`vibe.stream.botan`, `vibe.db.pgsql.pgsql`, `vibe.db.redis.sessionstore`).

## Documented-internal (ddox exclusions)

`dub.json`:

```
-ddoxFilterArgs: --ex vibe.core.drivers. --ex vibe.internal.
```

Those two prefixes are the **declared** non-API.

### `vibe.core.drivers.*`

| Module | Role |
|--------|------|
| `libasync.d` | The only `EventDriver` implementation (`LibasyncDriver`). ~2.1k lines. |
| `threadedfile.d` | Blocking file I/O on a helper path / POSIX `mkstemps`. Used by `vibe.core.file`. |
| `timerqueue.d` | Generic timer heap used by the libasync driver. |
| `utils.d` | WinSock error wrapping (`WSAErrorException`). |

`vibe.core.driver` is the **public** interface file (`EventDriver`, `DriverCore`, `getEventDriver`). It hard-imports `vibe.core.drivers.libasync` and types `getEventDriver()` as returning `LibasyncDriver`, not `EventDriver`. The abstraction is therefore **documentary**: you cannot swap backends without editing this module. Residual `version(VibeLibeventDriver)` / `VibeWin32Driver` / `VibeLibevDriver` / `VibeWinrtDriver` branches elsewhere are leftover from upstream vibe.d.

### `vibe.internal.*`

| Module | Role |
|--------|------|
| `meta/all.d` | Barrel for codegen helpers. |
| `meta/codegen.d`, `funcattr.d`, `traits.d`, `typetuple.d`, `uda.d` | Template UDA / trait machinery used by `vibe.web.web` (`@before`, `@after`, `PrivateAccessProxy`). |
| `newconcurrency.d` | Feature-detects Phobos `std.concurrency` flavor (`newStdConcurrency`). |
| `rangeutil.d` | Small range helpers. |

`vibe.web.web` **public-imports** `vibe.internal.meta.funcattr` (`PrivateAccessProxy`, `before`, `after`). So part of `vibe.internal` is on the consumer path for declarative web APIs. Treat `meta.funcattr` as de-facto public; the rest as private.

## Handler types (the HTTP contract)

`vibe.http.server` defines several callables that all collapse to `HTTPServerRequestDelegate`:

- `void function(HTTPServerRequest, HTTPServerResponse)`
- `void delegate(…)`
- `HTTPServerRequestHandler` / `…S` (`handleRequest` method)
- `scope` variants (`DelegateS` / `HandlerS` / `FunctionS`)

`listenHTTP`, `URLRouter.match`, and `registerWebInterface` all accept this family. A handler “completes” a request by writing to `HTTPServerResponse` (headers or body). Returning without writing is a fall-through (router) or a 404 (server).

`HTTPServerSettings` is a **class** (mutable, reference-shared). `dup` shallow-copies fields and deep-copies `bindAddresses`. TLS context, session store, and HTTP/2 settings are shared, not cloned as independent servers.

## Stream stack

```
InputStream / OutputStream / Stream / ConnectionStream   vibe.core.stream
        ▲
TCPConnection / UDPConnection / UDSConnection (linux)    vibe.core.net
        ▲
TLSStream (interface)                                    vibe.stream.tls
   BotanTLSStream | OpenSSLStream
        ▲
HTTP2Stream                                              vibe.http.http2
```

HTTP always talks to a `ConnectionStream`. TLS and HTTP/2 are optional wrappers. `createTLSStream` is the stable constructor; `vibe.stream.ssl` is a scheduled-for-deprecation alias layer.

## Version identifiers (interface, not just build)

Set by **this** library’s `dub.json` for every dependent:

| Version | Effect |
|---------|--------|
| `Have_vibe_d` | Compatibility flag. DUB would auto-define `Have_vibe_0` from the package name; this is a manual stand-in so old `version(Have_vibe_d)` code still compiles. |
| `EnableDebugger` | Paired with the absence of `VibeNoDebug`. The debugger module (`vibe.http.debugger`) and `mixin(Trace)` are compiled in unless the app overrides. |

Consumer-facing versions (set in **app** `dub.json` / `dub.sdl`, not here):

| Version | Contract |
|---------|----------|
| `VibeCustomMain` | Required. Suppresses `vibe.appmain.main`. App provides `main()` and calls `runEventLoop()`. |
| `VibeDefaultMain` | Compiles `appmain.main`, which then `static assert`s. **Unusable** in this fork. Several examples still set it. |
| `VibeNoDebug` | Strips `Trace` / breadcrumbs / `TaskDebugger` / `vibe.http.debugger`. |
| `DisableDebugger` | Used by examples; **no `version(DisableDebugger)` in `source/`**. Dead flag unless something outside this tree reads it. |
| `VibeRequestDebugger` | Extra hook inside `OnCapture` (`core.d`). |
| `VibeDebugCatchAll` | `runEventLoop` / request path catch `Throwable` instead of `Exception`. |
| `DeimosOpenSSL_3_0` | Required by the deimos openssl binding to select the 3.x API. Not referenced in this repo’s `.d` files; it is a **dependency** contract. |
| `TLSGC` | Used in example `versions`; **no matches in `source/`**. Possibly botan-side. Unverified. |
| `SQLite` | Same: README lists it; **no `version(SQLite)` in this tree**. SQLite is always compiled (`vibe.db.sqlite.sqlite3` imports `etc.c.sqlite3`). |
| `VibeNoTLS` | Skips TLS accept in `handleHTTPConnection`. |
| `VibeNoDefaultArgs` | Skip built-in `--uid`/`--gid` and related log options. |
| `VibeDisableCommandLineParsing` | `vibe.core.args` no-op. |
| `VibeIdleCollect` | Installs a GC timer in `shared static this`. |
| `VibeOldRouterImpl` | Linear `Route[]` instead of `MatchTree`. Deprecated path. |
| `VibeJsonFieldNames` / `JsonLineNumbers` / `JsonOptionalChaining` | JSON debug / convenience. |
| `LogAllocations` | Used by a test and `h2_request`; allocation tracing (debugger / memutils). Lightly read. |
| `RedisDebug` | Logs Redis request/reply. |

`@safe` is **not** part of the interface. README: the fork “doesn't use `@safe`”.

## Packaging surface

What a Windows consumer must satisfy is **part of the interface**, even though it is not a D symbol:

- Link libraries named in `libs-windows-x86_64` / `libs-windows-x86` (today: **absolute paths** — see [dependencies.md](dependencies.md)).
- `libs-windows`: `psapi`, `Crypt32`.
- `lflags-windows`: `/verbose:lib`, `/nodefaultlib:msvcrt`, `/nodefaultlib:vcruntime`.
- POSIX: `sqlite3`, `dl`, `pthread`, `brotlicommon`, `brotlidec`, `brotlienc`, `ssl`, `crypto`.

`buildRequirements: ["requireBoundsCheck"]` is also a contract: dependents inherit bounds checks.

## Invariants

- Do not treat `vibe.core.drivers` or `vibe.internal` (except `meta.funcattr` via web) as stable.
- Do not add a second event backend without changing `getEventDriver`’s return type and `setupEventDriver`.
- Do not revive `VibeDefaultMain` without deleting the `static assert` in `appmain.d` and restoring `finalizeCommandLineOptions` + `lowerPrivileges` + `runEventLoop`.
- Do not commit host-specific library paths.
- `ddox` exclusions are the documented privacy line; they are not enforced by the compiler.
