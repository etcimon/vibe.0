# TLS and crypto

Pin: `eb51b27` / `v1.2.1`. Loci: `source/vibe/stream/tls.d`, `ssl.d`, `botan.d` (~940), `openssl.d` (~980), `vibe/crypto/cryptorand.d`, `passwordhash.d`.

## Factory: Botan by default, OpenSSL for TLS 1.3

`createTLSContext(kind, ver = TLSVersion.any)` in `vibe.stream.tls`:

```
if (ver == TLSVersion.tls1_3)
    factory ??= OpenSSLContext
else
    factory ??= BotanTLSContext   // note: Botan ctor ignores `ver` here
gs_tlsContextFactory(kind, ver)
```

The factory is a process-global function pointer (`setTLSContextFactory` / `setSSLContextFactory`). The first `createTLSContext` call **wins** if the app has not set one. Mixing “first context was TLS 1.3” with “later context wants Botan defaults” is therefore order-dependent. Apps that care (README sample) construct `BotanTLSContext` **directly** and assign `settings.tlsContext`, bypassing the factory.

`createTLSStream(underlying, ctx, …)` delegates to `ctx.createStream`. State is inferred from `TLSContextKind` (client → connecting, server → accepting) or passed explicitly (`TLSStreamState.{connecting,accepting,connected}`).

`createTLSStreamFL` is **Botan-only**: `RefCounted!BotanTLSStream(...)` with a hard cast of `ctx` to `BotanTLSContext`. Using it with an OpenSSL context is undefined. The `auto` return type exists so non-Botan TUs do not import botan unless they call this function.

## Public TLS interface

`TLSStream` (`ConnectionStream`):

- `peerCertificate` → `TLSCertificateInformation` (OpenSSL fills this; Botan’s override `assert`s “Incompatible interface method” and exposes `x509Certificate` / Botan types instead).
- `getUserData()` — server stores `HTTPServerContext*` here for SNI/vhost.
- `alpn` — negotiated protocol; HTTP server branches on `"h2…"`.

`TLSContext`:

- `kind`: client / server / `serverSNI`
- `peerValidationMode`, `maxCertChainLength`, `peerValidationCallback`
- `sniCallback` / `alpnCallback` / `setClientALPN`
- `useCertificateChainFile` / `usePrivateKeyFile` / `useTrustedCertificateFile`
- `setUserData`
- `createStream`

SNI: `listenHTTPPlain.addVHost` wraps overlapping TLS listeners in `createTLSContext(TLSContextKind.serverSNI)` and a callback that searches `g_contexts` by `hostName`.

ALPN: see [overview.md](overview.md). Client default offer is on `HTTPClientSettings.http2.alpn`.

`vibe.stream.ssl` is a pure alias module (`SSLStream = TLSStream`, …) “scheduled for deprecation”. Examples (`https_server`) still use it.

## Botan path (`vibe.stream.botan`)

`version = X509` is forced at the top of the file.

`BotanTLSStream`:

- Wraps `TLSBlockingChannel` with `onRead`/`onWrite` bound to the underlying `TCPConnection`.
- Handshake runs in the constructor (`doHandshake`).
- Exposes Botan-native metadata: `TLSCiphersuite`, `TLSProtocolVersion`, `TLSServerInformation`, session id, session start, `X509Certificate`.
- `alpn` from `underlyingChannel().applicationProtocol()`.
- `static ~this` clears botan `global_state` (process teardown).

`BotanTLSContext`:

- Takes optional `TLSCredentialsManager`, `TLSPolicy`, `TLSSessionManager`, datagram flag.
- Defaults: `CustomTLSCredentials`, `CustomTLSPolicy`, `TLSSessionManagerInMemory` + `AutoSeededRNG`.
- README’s production comment mentions `TLSSessionManagerSQLite` — that type is **botan’s**, not defined in this repo.
- `defaultProtocolOffer` selects the offered version (`TLSProtocolVersion.latestTlsVersion()` in the sample).
- SNI and ALPN callbacks are wired into `TLSBlockingChannel` on the server constructor.

This is the path the README treats as canonical for HTTPS + HTTP/2 (Botan does ALPN; HTTP/2 then runs on the `TLSStream`).

**Unread:** `CustomTLSCredentials` / `CustomTLSPolicy` bodies, session resume, client-auth, datagram/DTLS (`m_is_datagram`), cipher-list helpers later in the file.

## OpenSSL path (`vibe.stream.openssl`)

`OpenSSLStream`:

- `SSL*` + custom `BIO` whose `ptr` is the D stream (`s_bio_methods`). Reads/writes yield the vibe task when the TCP connection blocks.
- `SSL_accept` / `SSL_connect` in the constructor for accepting/connecting states.
- Client: `SSL_CTRL_SET_TLSEXT_HOSTNAME` (SNI) and optional per-stream ALPN.
- Peer verify data hung off `SSL_get_ex_data` during handshake.
- `peerCertificate` populated from `X509` (this is the interface-compatible implementation).

`OpenSSLContext` (rest of the file, **sampled**): context setup, cipher list, cert files, ALPN set, verify callback. Imports `deimos.openssl.{bio,err,rand,ssl,x509v3}`.

Needs:

- DUB `openssl ~>3.3.4` **plus** the patched deimos (`http2fix`) for HTTP/2 / ALPN bits.
- Version `DeimosOpenSSL_3_0`.
- Native `libssl`/`libcrypto` — on this pin, Windows points at `C:/Program Files/OpenSSL/lib/...` (see [dependencies.md](dependencies.md)).

Bundled `lib/openssl-win64-x64` was configured **TLS 1.3 only** (`no-tls1 no-tls1_1 no-tls1_2 enable-tls1_3`, `no-sock`, `no-shared`, …). That matches “OpenSSL is for 1.3” **if** those blobs are what you link. The `Program Files` path may be a different build. Binding a 1.3-only lib into `OpenSSLContext` and then asking it for older versions will fail; the factory already avoids that by sending non-1.3 to Botan.

`#version(VibeNoTLS)` skips TLS accept in the HTTP server (plaintext only).

## Which stack does HTTP use?

```
settings.tlsContext  ──null──►  raw TCP  (h2c / HTTP/1.1)
        │
        ▼
createTLSStream(tcp, ctx, accepting)
        │
        ├── BotanTLSStream.alpn  ──"h2*"──►  HTTP2Session on TLS
        └── OpenSSLStream.alpn   ──"h2*"──►  same
        │
        └── else HTTP/1.1 on TLSStream
```

SMTP (`vibe.mail.smtp`) uses `vibe.stream.ssl` for SMTPS / STARTTLS. PostgreSQL can wrap a `TLSStream`. The HTTP client uses `settings.tlsContext` or `createTLSContext(client)` + optional `HTTPClient.setTLSSetupCallback`.

## Crypto outside TLS

### `vibe.crypto.cryptorand`

- `secureRNG()` → process/thread `SystemRNG` (`RandomNumberStream`).
- Windows: `CryptGenRandom` / BCrypt path (read the Windows branch).
- BSD/macOS: `arc4random`.
- Linux: `getrandom` if `mir.linux._asm.unistd.NR_getrandom` compiles, else `/dev/urandom`.
- `SHA1HashMixerRNG` used by HTTP sessions (module comment: “TODO: Use Whirlpool or SHA-512”).

### `vibe.crypto.passwordhash`

`generateSimplePasswordHash` / `testSimplePasswordHash`: **MD5 + 4-byte salt**, `deprecated` (“insecure… use dauth or scrypt”). Still in the **barrel**. Do not use for new auth.

No other hash/KDF module lives under `vibe.crypto`. Botan is the intended “full suite”.

## Invariants

- Factory default is **not** “always Botan”: a prior `TLSVersion.tls1_3` create permanently installs OpenSSL if the app did not set a factory.
- `createTLSStreamFL` is Botan-only.
- Botan and OpenSSL `TLSStream`s are **not** feature-equivalent (`peerCertificate` vs `x509Certificate`).
- HTTP/2 over TLS requires an ALPN implementation in the chosen stack and a deimos OpenSSL new enough for the OpenSSL path.
- Do not assume the bundled Windows OpenSSL blobs are what `dub.json` links.
- Session IDs are SHA-1 mixed RNG, not botan RNG, and only init on `"V|"` threads.

## Unread

- Most of `OpenSSLContext` (cipher lists, verify, session ids).
- Botan credential/policy/session-manager customization.
- `stream.botan` handshake error paths and `OnAlert` / `OnHandshakeComplete`.
- Whether `TLSVersion.any` on Botan actually offers 1.3 (botan policy) or stops at 1.2 — **open**.
- SMTP TLS details, PostgreSQL `ssl=require`.
- `crypto.cryptorand` Windows CAPI vs BCrypt exact API.
