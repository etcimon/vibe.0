# Open questions

Pin: `eb51b27` / `v1.2.1`. Items below are unresolved from this notes pass. None of them were “fixed.”

## Green / host

1. **Windows absolute `libs-*` paths** — packaging contract. Who is allowed to change them, and to what (relative `lib/`, `lflags`, optional sub-package)? Not decided here.
2. **Which OpenSSL does a Windows consumer actually need?** `Program Files` install vs `lib/openssl-win64-x64` (TLS 1.3-only, `no-sock`). Mixing them is untested.
3. **Patched deimos openssl** (`http2fix` / PR #115) — is it still required on openssl 3.3.4, or has upstream merged enough ALPN/HTTP2? Not fetched.
4. **Botan green** — previously blocked on this host. Current botan `~>1.13.0` + this compiler: unknown.
5. **`dub build` of the library without `VibeCustomMain`** — `appmain.d` should `static assert`. Confirm when a compiler is usable.
6. **POSIX link line** — system brotli/sqlite/ssl assumed. Versions unknown.
7. **`memutils` not in `dub.json`** — which dependency version is actually used? Pin drift risk.

## Fork identity / leftover vibe.d

8. `vibeVersionString` is `"0.7.23"`; git tag is `v1.2.1`. Should UA / `Server` headers change? That is an HTTP fingerprint change.
9. `Have_vibe_d` vs real DUB `Have_vibe_0`. Any consumer still keys on the former?
10. `CHANGELOG.md` stops at upstream 0.7.23. Fork history (HTTP/2, botan, pgsql, memutils, main() kill) is undocumented in-tree.
11. `CONTRIBUTING.md` / `todo.txt` / `homepage` still describe official vibe.d (Diet, `dub test`, vibedist).
12. Examples still on `VibeDefaultMain` + `shared static this`. Intentional breakage or incomplete migration?
13. Tests depend on DUB name `vibe-d`. Rename oversight?

## Dead or suspicious versions

14. `DisableDebugger`, `TLSGC`, `SQLite` appear in README/examples but **not** as `version(...)` in `source/`. Botan/memutils-side? Dead?
15. `VibeLibeventDriver` / `VibeWin32Driver` / `VibeLibevDriver` / `VibeWinrtDriver` remnants — safe to delete, or still compiled by someone?
16. `vibe.http.dist` is `version(none)`. Remove vs keep?
17. `HTTPRouter` interface “planned to be removed” — still here.

## Behavior unknowns (not executed)

18. HTTP/2 push, priority, flow control under load.
19. h2c upgrade + request body already buffered (`MemoryStream` splice in `handleRequest`) — correctness on large bodies.
20. `Expect: 100-continue` written as `HTTP/1.1` even on TLS/h2? Dead code on h2 (headers already parsed)?
21. Client `maxInactivity` comment: “This doesn't currently work.”
22. `useCompressionIfPossible` “known issues with GZIP” (settings comment) vs default **true**.
23. Fileserver directory index / range requests / cache headers — not verified.
24. WebSocket over HTTP/2.
25. `HTTPServerOption.distribute` correctness with HTTP/2 sessions (thread affinity of a session).
26. WinSock init on the libasync path (no `WSAStartup` in `core.d` unless old driver versions).
27. `createTLSContext` factory latching (first call chooses Botan vs OpenSSL globally).
28. Botan `TLSVersion.any` vs TLS 1.3 offer.
29. PostgreSQL SCRAM / modern auth — documented unsupported; still true.
30. Redis AUTH + ACL users.

## Unread source (explicit)

Large or only-sampled. Do not pretend these were reviewed:

| Area | Files |
|------|--------|
| HTML DOM | `data/dom.d` (7.2k) |
| XML | `data/xml.d` |
| Brotli C API + stream | `data/brotli.d`, `stream/brotli.d` |
| SQLite wrapper | most of `db/sqlite/sqlite3.d` |
| PostgreSQL protocol | most of `db/pgsql/pgsql.d` |
| Redis commands / pubsub | most of `db/redis/*` |
| HTTP/2 connector, push, client session | most of `http/http2.d` after the stream/session types |
| HTTP response write path | `HTTPServerResponse` in `server.d` |
| HTTP client internals | second half of `client.d` |
| WebSockets | `http/websockets.d` |
| Cookie jar | `http/cookiejar.d`, `cookiejar_dates.d` |
| Digest auth | `http/auth/digest_auth.d` |
| Access log tokens | `http/log.d` |
| Fileserver `sendFile` | rest of `fileserver.d` |
| Web interface codegen | most of `web/web.d`, `web/common.d`, `web/validation.d` |
| Driver: UDP, UDS, files, watchers, distribute | most of `drivers/libasync.d` after TCP/timers |
| `VibeDriverCore` internals | lower half of `core.d` |
| Concurrency / scheduler | `core/concurrency.d` |
| Log implementation | `core/log.d` |
| Daemonize | `daemonize/*` (esp. `windows.d`) |
| OpenSSL context | most of `stream/openssl.d` |
| Botan credentials/policy | most of `stream/botan.d` |
| Stream odds | `bufcomp`, `multicast`, `taskpipe`, `stdio`, `base64`, `wrapper` |
| Inet | `mimetypes.d` (tables), `urltransfer.d`, `message.d` |
| SMTP | `mail/smtp.d` |
| Meta codegen | `internal/meta/*` |
| Utils | `utils/memory.d`, `array.d`, `validation.d` |
| Views | `views/capture.html` (debugger?) |
| Benches | `examples/bench-*` |

## RISC-V

31. Latent only. Needs ldc2/gdc riscv64, libasync epoll, system ssl/sqlite/brotli, botan on that triple. No in-tree cross file. Fiber/TLS/atomic assumptions in libasync/botan/memutils are **their** questions, not this repo’s.

## Interface changes that would be load-bearing (do not sneak in)

- Rewriting `libs-windows-*`.
- Adding `memutils` to `dependencies`.
- Deleting `VibeDefaultMain` / `appmain.main` / `Have_vibe_d`.
- Changing `getEventDriver`’s return type.
- Flipping default `useCompressionIfPossible` or HTTP/2 on/off.
- Claiming green without a log on this host.
