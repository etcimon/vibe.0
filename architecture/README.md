# vibe.0 architecture notes

Untracked-local notes for this clone. Not upstream documentation. Not official vibe.d.

```
clone:     vibe.0
upstream:  https://github.com/etcimon/vibe.0.git
pin:       feature/botan-delegate-sync @ 7b77638 (from master / tag v1.2.1+)
           7b77638c (Require memutils >=1.0.12…)
license:   MIT (plus Boost/BSD file exceptions; see LICENSE.txt)
dub name:  vibe-0
target:    library
identity:  2015-era vibe.d fork with libasync, botan, libhttp2, memutils
green:     NOT verified — blocked (see below)
```

**Is:** async I/O / HTTP / TLS / data / DB toolkit under `source/vibe/`.  
**Is not:** official [vibe.d](https://github.com/rejectedsoftware/vibe.d). The barrel still says “vibe.d”, `vibeVersionString` is still `"0.7.23"`, and the homepage in `dub.json` still points at `http://vibed.org/`. Those are leftover identities from the fork point, not a claim that this is the same project.

## Green status (unverified)

`green_command` from the agent stub: `dub build --compiler=ldc2`.

**Not run here.** Blocked before a compile can even reach botan:

1. `dub.json` `libs-windows-x86_64` / `libs-windows-x86` are **absolute paths on another machine** (`C:/Program Files/OpenSSL/...`, `C:/users/etcim/Development/vibe.0/lib/...`, `F:/Development/brotli/out/installed/lib/...`). The linker will not find them on this host.
2. README requires a patched deimos openssl (`DeimosOpenSSL_3_0`) via a separate `dub add-local`. That local package is not present here.
3. Botan (DUB `botan ~>1.13.0`) was previously a green blocker on this host; not re-probed.

Do not invent a path-rewrite “fix”. The keys are a **Windows packaging / interface contract**. Changing them changes what every Windows consumer must ship. Document only.

## How to read these notes

| File | What it is |
|------|------------|
| [overview.md](overview.md) | End-to-end journey: `listenHTTP` → TCP accept → TLS/ALPN → HTTP/1.1 or HTTP/2 → `URLRouter` → response, through the libasync driver |
| [interface.md](interface.md) | Public `vibe.*` surface vs `vibe.internal` / `vibe.core.drivers`; barrel imports; versions |
| [dependencies.md](dependencies.md) | DUB packages + C libs (OpenSSL, SQLite, brotli); absolute Windows paths; undeclared `memutils` |
| [build-test.md](build-test.md) | `dub.json`, `mainSourceFile`, versions, `examples/`, `tests/`, why default `main` is dead |
| [core-event.md](core-event.md) | Event loop, tasks/fibers, `EventDriver` / `DriverCore`, libasync, file I/O |
| [http.md](http.md) | `vibe.http` server, client, HTTP/2 via libhttp2, router, websockets, proxy |
| [tls-crypto.md](tls-crypto.md) | Botan vs OpenSSL factory, streams, password hash, CSPRNG |
| [botan-delegates.md](botan-delegates.md) | Frozen botan delegate attach; V1 = Botan TLS 1.3 via same `BotanTLSStream` |
| [data-db.md](data-db.md) | `vibe.data` (JSON, XML, DOM, serialization, brotli) and `vibe.db` (sqlite, redis, pgsql) |
| [open-questions.md](open-questions.md) | Unread areas, packaging debt, RISC-V affinity, leftover vibe.d pieces |

Start at [overview.md](overview.md) if you need the request path. Start at [interface.md](interface.md) if you need “what may a consumer import”. Start at [dependencies.md](dependencies.md) if you need why a Windows link fails.

## Tree (high level)

```
source/vibe/          library sources (this is the product)
  appmain.d           default main() — compile-time dead in this fork
  vibe.d / d.d        barrel imports (nearly identical)
  core/               event loop, tasks, net, file, sync, drivers/libasync
  http/               server, client, HTTP/2, router, websockets, …
  stream/             TLS (botan/openssl), zlib, brotli, wrappers
  data/               JSON, serialization, XML, DOM, brotli C bindings
  db/                 sqlite (vendored d2sqlite3), redis, pgsql
  web/                declarative web interface (no vibe.web.rest)
  inet/ mail/ crypto/ daemonize/ textfilter/ utils/ internal/
examples/             23 small apps; mixed VibeCustomMain / VibeDefaultMain
tests/                4 integration tests; 3 still depend on name "vibe-d"
lib/                  bundled Windows .lib blobs (not what dub.json links)
architecture/         these notes (untracked)
```

## Loci (first places to open)

| Concern | Path |
|---------|------|
| Package contract | `dub.json` |
| Default / custom main | `source/vibe/appmain.d` |
| Barrel | `source/vibe/vibe.d`, `source/vibe/d.d` |
| Event loop + task spawn | `source/vibe/core/core.d` |
| Driver interface + singleton | `source/vibe/core/driver.d` |
| libasync backend | `source/vibe/core/drivers/libasync.d` |
| TCP listen / connect | `source/vibe/core/net.d` |
| HTTP listen + connection | `source/vibe/http/server.d` (`listenHTTP`, `handleHTTPConnection`, `handleRequest`) |
| Router | `source/vibe/http/router.d` |
| HTTP/2 session | `source/vibe/http/http2.d` |
| HTTP client + h2 client | `source/vibe/http/client.d` |
| TLS factory | `source/vibe/stream/tls.d` |
| Botan / OpenSSL impls | `source/vibe/stream/botan.d`, `source/vibe/stream/openssl.d` |
| Declarative web | `source/vibe/web/web.d` |

## Invariants (short)

- Consumers use **`VibeCustomMain`** and their own `main()`, then `runEventLoop()`. The fork’s default `main()` `static assert`s.
- The only event backend is **libasync**. `EventDriver` is an interface; `getEventDriver()` returns `LibasyncDriver`.
- Tasks are fibers (`TaskFiber`) owned by one thread. I/O looks blocking; the driver yields the fiber.
- HTTP is a callback on a TCP connection. `listenHTTP` → `listenTCP` → `handleHTTPConnection` → `handleRequest` → user delegate / `URLRouter`.
- HTTP/2 is first-class: ALPN `h2`, prior-knowledge preface, and h2c upgrade. Implementation is `libhttp2`.
- TLS 1.3 goes through OpenSSL; everything else defaults to Botan. `createTLSStreamFL` is Botan-only.
- Memory: `memutils` (`ThreadMem`, `ScopedPool`, `Vector`, `HashMap`, …) is used throughout. GC avoidance is a design goal, not a proof.
- Do not commit machine-specific library paths.

## Unread / lightly read

Marked in [open-questions.md](open-questions.md). Large vendored files (`data/dom.d` ~7.2k lines, `db/pgsql/pgsql.d`, `db/sqlite/sqlite3.d`) were sampled, not line-walked. Diet templates, Mongo, `vibe.web.rest`, and the old libevent/win32/libev drivers are **absent** (fork deletions), not unread.
