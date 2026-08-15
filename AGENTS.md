# vibe.0 — Agent Guider (untracked-local)

```
id: vibe.0
upstream: https://github.com/etcimon/vibe.0.git
pin: master @ eb51b27 (tag v1.2.1)
     eb51b2704674317ff8b10062d7907ba43fd973db
mechanism: nested-clone
purpose: Async I/O / web toolkit (2015 vibe.d fork) with libasync, botan, libhttp2
green_command: dub build --compiler=ldc2
green_cell: Windows x64 / LDC 1.42.0 — library + examples/http_static_server (2026-08-14)
green_verified: yes
riscv_affinity: latent
persistence: untracked-local
notes: architecture/
```

**Is:** framework under `source/` (dub name **`vibe-0`**, `targetType: library`).  
**Is not:** official `vibe.d`. Barrel comments, `vibeVersionString` (`"0.7.23"`), `Server`/`User-Agent`, and `homepage` still say vibe.d — leftover identity.

**License:** MIT (Ludwig / Cimon). File exceptions in `LICENSE.txt`: Boost (`data/dom.d`, `data/xml.d`, `db/pgsql/pgsql.d`, `db/sqlite/sqlite3.d`), BSD-3 (`http/cookiejar_dates.d`).

## How it works (one screen)

Consumer sets **`VibeCustomMain`**, writes `main()`, calls `listenHTTP` then `runEventLoop()`. Default `main()` in `source/vibe/appmain.d` `static assert`s.

`vibe.core.core` module ctor starts a **libasync** `LibasyncDriver` (only backend). Tasks are fibers. `listenTCP` accept runs `handleHTTPConnection` in a new task. Optional TLS (`vibe.stream.tls`: Botan default, OpenSSL if `TLSVersion.tls1_3`) + ALPN. HTTP/1.1 keep-alive loop **or** `HTTP2Session` (libhttp2: ALPN / preface / h2c upgrade). `URLRouter` / `registerWebInterface` write the response.

Elaborate notes: [`architecture/`](architecture/README.md).

## Loci

| Topic | Path |
|-------|------|
| Package / link contract | `dub.json` |
| Dead default main | `source/vibe/appmain.d` |
| Barrel | `source/vibe/vibe.d`, `source/vibe/d.d` |
| Event loop / tasks | `source/vibe/core/core.d` |
| Driver singleton | `source/vibe/core/driver.d` |
| libasync backend | `source/vibe/core/drivers/libasync.d` |
| TCP façade | `source/vibe/core/net.d` |
| HTTP listen / conn / req | `source/vibe/http/server.d` |
| Router | `source/vibe/http/router.d` |
| HTTP/2 | `source/vibe/http/http2.d` |
| HTTP client | `source/vibe/http/client.d` |
| TLS factory | `source/vibe/stream/tls.d` |
| Botan / OpenSSL | `source/vibe/stream/botan.d`, `openssl.d` |
| Web interface | `source/vibe/web/web.d` |

Public vs `vibe.internal` / `vibe.core.drivers`: [`architecture/interface.md`](architecture/interface.md).

## Dependencies

DUB: `libhttp2 ~>1.0.0`, `botan ~>1.13.0`, `libasync ~>0.9.0`, `openssl ~>3.3.4`.  
**Undeclared but required:** `memutils` (used throughout; comes in transitively today).

**Host debt (fact):** `libs-windows-x86_64` / `libs-windows-x86` are **absolute paths** on another machine (OpenSSL under `C:/Program Files/OpenSSL`, sqlite under `C:/users/etcim/Development/vibe.0/lib`, brotli under `F:/Development/brotli/...` and the author’s x86 `lib/`). `lib/` has bundled sqlite/brotli/openssl blobs that **x64 `dub.json` does not point at**. README requires a patched deimos openssl (`DeimosOpenSSL_3_0`) via `dub add-local`.

POSIX: `sqlite3 dl pthread brotlicommon brotlidec brotlienc ssl crypto`.

Details: [`architecture/dependencies.md`](architecture/dependencies.md).

## Invariants

- Do not commit machine-specific library paths. Path cleanup is an **interface/packaging** change for Windows consumers — do not “fix” it casually.
- Do not treat this as official vibe.d. Missing here: Diet/`vibe.templ`, `vibe.web.rest`, Mongo, libevent/win32/libev drivers, split `vibe-d:*` packages.
- Do not add a second event backend without changing `getEventDriver()` (typed as `LibasyncDriver`).
- Consumers must use `VibeCustomMain` + `runEventLoop()`. Do not revive `VibeDefaultMain` without rewriting `appmain.d`.
- Listen on one thread (`g_ctor`). Tasks stay on their thread.
- Threads that should own a driver must be named `"V|…"`.
- Do not record `green_verified: yes` without a build log on this host.
- Do not claim RISC-V support; affinity is latent (portable D + C libs, no in-tree cross).
- Notes stay **inside this clone**. Do not commit. Do not edit host-tracked scaffold outside this tree.

## Versions that matter

Library always sets `Have_vibe_d`, `EnableDebugger`.  
Apps: `VibeCustomMain` required. `VibeNoDebug` strips `mixin(Trace)` / debugger. `DeimosOpenSSL_3_0` is a **deimos** contract. `DisableDebugger`, `TLSGC`, `SQLite` appear in README/examples but are **not** matched in `source/`.

## Green

**Unverified.** Blocked before compile/link on this Windows host:

1. Absolute `libs-windows-*` paths do not exist here.
2. Patched openssl + `DeimosOpenSSL_3_0` not registered.
3. Botan previously failed to build on this host (not re-probed).

Even with paths fixed, `dub build` of the library may still hit `appmain.d`’s `static assert` unless `VibeCustomMain` is added to the library recipe or the command line. A more realistic first app build is `examples/http_static_server` (already `VibeCustomMain`).

## Open (short)

Normalize Windows lib keys; add explicit `memutils`; rename test deps `vibe-d` → `vibe-0`; migrate `VibeDefaultMain` examples; run green after botan + openssl exist; decide whether `vibeVersionString` should become `1.2.1`. Full list: [`architecture/open-questions.md`](architecture/open-questions.md), [`AGENTS-todo.md`](AGENTS-todo.md).
