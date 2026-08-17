# Botan TLS attachment (delegates)

Working branch: **`feature/botan-delegate-sync`** (from `master` `7b77638`). Merges to
**this** repository’s `master` (etcimon/vibe.0). Botan work lives on
`../botan` `feature/randombit-sync`. Botan’s copy of this contract:
`../botan/architecture/vibe-delegates.md`.

## Factory today

`vibe.stream.tls.createTLSContext` (`tls.d:81–98`):

- One Botan factory honours `ver` on every call (no first-call latch between
  1.3 and 1.2).
- `TLSVersion.any` / `tls1_2` → `BotanTLSContext` + `CustomTLSPolicy` min 1.2,
  offer botan `latestTlsVersion()` (still **1.2**).
- `TLSVersion.tls1_3` → same stream, `defaultProtocolOffer = TLS_V13`, policy
  min=max=1.3.
- `tls1` / `tls1_1` / `ssl3` raise only the policy minimum; offer stays 1.2.
- `dtls1` sets the datagram flag and DTLS 1.2 min/offer.

First factory install still wins process-wide (`setTLSContextFactory` can
install OpenSSL). Apps that care construct `BotanTLSContext` directly
(`settings.tlsContext`).

`createTLSStreamFL` is Botan-only (`RefCounted!BotanTLSStream`).

`vibe.stream.botan` forces `version = X509`. `vibe.stream.bufcomp` is `version(Botan)`.

## How the stream attaches (do not invent a second path)

`BotanTLSStream` builds a `TLSBlockingChannel` with **the same four I/O/event
delegates** botan already documents:

| Delegate | botan alias | `BotanTLSStream` method | Wire |
|---|---|---|---|
| ciphertext out | `DataWriter` | `onWrite` | `TCPConnection.write` |
| ciphertext in | `DataReader` | `onRead` | `TCPConnection.read` / `readBuf` |
| alert | `OnAlert` | `onAlert` | optional `m_alert_cb` |
| handshake done | `OnHandshakeComplete` | `onHandhsakeComplete` | fills session/cipher/version/peer cert; optional `m_handshake_complete` |

Client ctor: `botan.d:95` — also passes `m_session_manager`, `m_credentials`,
`m_policy`, `*m_rng`, `m_server_info`, `m_offer_version`, `m_clientOffers`.

Server ctor: `botan.d:111` — same objects plus `&nextProtocolHandler`,
`&sniHandler`, `m_is_datagram`.

`doHandshake` (`botan.d:128`) calls botan’s blocking loop (`read_fn` →
`receivedData` until `isActive()`). `onBeforeHandshake` / `onAfterHandshake`
are vibe-only and stay outside botan.

`CustomTLSPolicy` overrides botan `TLSPolicy` virtuals (`acceptableProtocolVersion`,
`ciphersuiteList`, `allowedEccCurves`, `chooseCurve`, `minimumDhGroupSize`,
`sessionTicketLifetime`, `latestSupportedVersion`, `allowServerInitiatedRenegotiation`,
`allowedSignatureMethods`). Default `m_min_ver = TLS_V12`, min DH 2048, no
server-initiated renegotiation. `applyTlsVersion` sets min/offer/max without
touching botan `latestTlsVersion()`.

## TLS 1.2 / 1.3 selection (landed)

Botan has `version(TLS_13)` and `TLSProtocolVersion.TLS_V13` **without**
changing `TLSBlockingChannel` ctors or `latestTlsVersion()` (stays 1.2).

```
// tls.d createTLSContext — single Botan factory
return new BotanTLSContext(kind, ver);
```

Still `BotanTLSStream`. Still the four delegates. OpenSSL remains available if
someone sets the factory.

Do not change `CustomTLSPolicy` virtual signatures. New 1.3 hooks on botan
`TLSPolicy` must have defaults.

`useTrustedCertificateFile` loads a multi-cert PEM bundle via
`CertificateStoreInMemory.addFromFile`. `useSystemCertificateStore` attaches
`CertificateStoreSystem` (Windows Root/CA, POSIX CA bundles). Client contexts
with `checkTrust` and no stores load the system store automatically.
`certChain` keeps comparing `m_key.algoName` to `"RSA"` / `"ECDSA"` /
`"Ed25519"`; botan maps TLS 1.3 scheme names before that call
(`../botan/architecture/cert-stores.md`).

OCSP: `TLSContext.ocspChecking` sets `PathValidationRestrictions.ocspAllIntermediates`.
`vibe.http.client` installs botan `setHttpExchangeHandler` (shared static this)
with `requestHTTP` and `maxRedirects = 0` (S4). Not a `TLSBlockingChannel`
argument, and not imported from `vibe.stream.botan` (module-ctor cycle).

## Invariants

- No Botan 3 `Callbacks` type in this tree.
- `peerCertificate` on `BotanTLSStream` still asserts; use `x509Certificate`.
  Fixing that is a separate vibe pass, not a botan API break.
- `static ~this` still `setGlobalState(null)`.

## Unread / leftover

- Whether `TLSVersion.any` should one day offer 1.3 on Botan — **no**, unless
  an app sets `defaultProtocolOffer`. Factory `any` stays Botan 1.2 default.
- `setDHParams` on Botan still asserts (OpenSSL-shaped PEM DH helper).
- OpenSSL `useSystemCertificateStore` uses `SSL_CTX_set_default_verify_paths`
  plus POSIX bundle paths; it does not enumerate the Windows CryptoAPI store.
