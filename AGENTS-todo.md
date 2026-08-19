# vibe.0 — agent todo (untracked-local)

Living list. Do not treat items as assigned work unless a later prompt says so.
Pin: `7b77638` on **`feature/botan-delegate-sync`** (merge to this repo’s master).

## Botan TLS 1.3 attach (after botan T13d)

- [x] **V1:** `createTLSContext(tls1_3)` builds `BotanTLSContext` + `defaultProtocolOffer = TLS_V13`. `BotanTLSStream` and the four delegates unchanged. OpenSSL remains available via `setTLSContextFactory`.
- [x] **V2:** Factory honours every `TLSVersion` (1.2/1.3* selection, no first-call latch). `CustomTLSPolicy` latest defaults (DH 2048, no server-initiated renegotiation, Ed25519). `useTrustedCertificateFile` PEM bundles; `useSystemCertificateStore`; client `checkTrust` auto-loads the OS store. `ocspChecking` + vibe `requestHTTP` `maxRedirects=0` on botan `setHttpExchangeHandler`. `useCertificateChainFile` loads leaf+CA. `setCipherList` / `setECDHCurve` on `CustomTLSPolicy`. Botan `latestTlsVersion()` still 1.2.

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
- [x] `examples/https_server`: `VibeCustomMain` + Botan `tlsContext` + `TLSGC` + `--workers` (`setupWorkerThreads` + `HTTPServerOption.distribute`). ECDSA P-256 cert (`ecdsa.crt`/`ecdsa.key`); tls1_2 offer / max 1.3.
- [x] `examples/https_server_sni`: Botan `createTLSContext` + `TLSGC` + `VibeCustomMain` (was `createSSLContext` / `VibeDefaultMain`).
- [x] `createCreds()` ECDSA P-256 (was RSA-2048) so `tests/botan_tls13` hits botan `CurveGFpP256` Solinas. memutils pin **1.0.14**, botan **3.13.1**.
- [x] Public `setupWorkerThreads(size_t num = 0)` for worker HTTPS (V\| threads, TLSGC per thread).
- [ ] Remaining examples on `VibeDefaultMain` / `shared static this`.
- [ ] Clarify or remove unused versions: `DisableDebugger`, `SQLite` (`TLSGC` is used by https_server + botan_tls13).
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
