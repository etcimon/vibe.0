# vibe.0 — agent todo (untracked-local)

Living list. Do not treat items as assigned work unless a later prompt says so. Pin: `eb51b27` / `v1.2.1`.

## Blocked / do not fake

- [ ] **Green:** `dub build --compiler=ldc2` (library) and `examples/http_static_server`. Blocked on:
  - absolute `libs-windows-x86_64` / `x86` paths in `dub.json`
  - `dub add-local` patched openssl + `DeimosOpenSSL_3_0`
  - botan build on this host
- [ ] Confirm whether library `dub build` also dies on `appmain.d` `static assert` (no `VibeCustomMain` in library `versions`).
- [ ] POSIX green (system ssl/sqlite/brotli) — not attempted.

## Packaging contract (interface changes — do not sneak)

- [ ] Decide how Windows consumers should find OpenSSL / sqlite / brotli (relative `lib/`, `lflags`, optional native subpackage). **Do not rewrite paths without an explicit packaging task.**
- [ ] Declare `memutils` in `dependencies` (today implicit).
- [ ] Align bundled `lib/openssl-win64-x64` and `lib/brotli-win64-x64` with what `dub.json` actually links (x64 currently ignores those folders).
- [ ] Document which OpenSSL build is required (full vs TLS-1.3-only `no-sock` blobs).

## Fork hygiene (source, not this notes pass)

- [ ] Tests: `"vibe-d"` → `"vibe-0"` in `tests/args`, `tests/redis`, `tests/tcpproxy`.
- [ ] Examples on `VibeDefaultMain` / `shared static this` — migrate to `VibeCustomMain` + `main()` + `runEventLoop()`, or they stay unbuildable.
- [ ] Clarify or remove unused versions: `DisableDebugger`, `TLSGC`, `SQLite`.
- [ ] `vibeVersionString` `"0.7.23"` vs tag `v1.2.1` (UA / `Server` header impact).
- [ ] `CHANGELOG.md` / `CONTRIBUTING.md` / `todo.txt` still describe upstream vibe.d.

## Architecture notes — unread follow-ups

See `architecture/open-questions.md` for the file list. Highest leverage if someone continues reading:

1. `http/http2.d` connector + client session
2. `HTTPServerResponse` write path
3. `drivers/libasync.d` UDP/UDS/file/distribute
4. `db/pgsql/pgsql.d` auth + SSL
5. `stream/openssl.d` + botan credentials
6. `web/web.d` codegen (matches README `UserAPI`)

## Out of scope unless asked

- Committing these notes
- Editing host-tracked scaffold outside this clone
- Inventing a RISC-V port
- Reintroducing Diet, Mongo, `vibe.web.rest`, or libevent
