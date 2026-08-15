# Dependencies

Pin: `eb51b27` / `v1.2.1`. Source of truth: `dub.json` plus what the D sources actually `import`.

## DUB packages (`dub.json` `dependencies`)

| Package | Version | Role in this tree |
|---------|---------|-------------------|
| `libhttp2` | `~>1.0.0` | HTTP/2 framing, HPACK, sessions. Imported by `vibe.http.http2` (`libhttp2.types`, `.connector`, `.session`, `.buffers`, `.frame`, `.constants`, `.helpers`). |
| `botan` | `~>1.13.0` | Default TLS implementation (`vibe.stream.botan`) and the full crypto suite the README advertises. Also pulled into example apps that construct `BotanTLSContext` / `X509Certificate` directly. |
| `libasync` | `~>0.9.0` | Event loop, TCP/UDP, signals, timers, `NetworkAddress`. `vibe.core.drivers.libasync` is a backend, not a peer. `vibe.core.net` re-exports `libasync.events.NetworkAddress`. Worker teardown calls `libasync.threads.destroyAsyncThreads`. |
| `openssl` | `~>3.3.4` | deimos OpenSSL bindings used by `vibe.stream.openssl`. **Not sufficient as shipped:** README requires a patched fork (`etcimon/openssl` branch `http2fix`, PR D-Programming-Deimos/openssl#115) registered with `dub add-local`, plus version `DeimosOpenSSL_3_0`. |

There is **no** `memutils` entry in `dub.json`. The sources import it everywhere (`memutils.utils`, `.circularbuffer`, `.hashmap`, `.vector`, `.scoped`, `.refcounted`, `.dictionarylist`, `.allocators`, `.unique`, `.rbtree`). It arrives transitively (botan and/or libasync historically depend on it). That is an **undeclared direct dependency**: this library’s API and internals are unusable without it. A packaging cleanup would add `memutils` explicitly; that is an interface change for DUB resolution, not done here.

No `vibe-d` dependency. This package **is** the framework. Tests that still depend on `"vibe-d"` are stale (see [build-test.md](build-test.md)).

## C / system libraries

### POSIX (`libs-posix`)

`sqlite3`, `dl`, `pthread`, `brotlicommon`, `brotlidec`, `brotlienc`, `ssl`, `crypto`.

These are linker names only. Headers come from deimos (`etc.c.sqlite3`, `deimos.openssl.*`) and from `vibe.data.brotli` (vendored C API).

### Windows (all flavors)

`libs-windows`: `psapi`, `Crypt32` (process info + Windows crypto / cert store; used by OpenSSL and daemonize).

`lflags-windows`: `/verbose:lib /nodefaultlib:msvcrt /nodefaultlib:vcruntime` — forces a specific CRT story (static / non-default). Combined with the OpenSSL blobs built against a particular MSVC (see `lib/openssl-win64-x64/version.txt`: `MSVC\14.16.27023`), this is a **toolchain pin in all but name**.

### Windows x64 / x86 — absolute machine paths (packaging debt)

**Fact.** These arrays are copied from `dub.json` as they exist at `eb51b27`. They are not suggestions; they are what DUB will pass to the linker.

`libs-windows-x86_64`:

```
C:/Program Files/OpenSSL/lib/libssl
C:/Program Files/OpenSSL/lib/libcrypto
C:/users/etcim/Development/vibe.0/lib/sqlite3_x64
F:/Development/brotli/out/installed/lib/brotlicommon
F:/Development/brotli/out/installed/lib/brotlienc
F:/Development/brotli/out/installed/lib/brotlidec
```

`libs-windows-x86`:

```
C:/Program Files/OpenSSL/lib/libssl
C:/Program Files/OpenSSL/lib/libcrypto
C:/users/etcim/Development/vibe.0/lib/sqlite3_x86
C:/users/etcim/Development/vibe.0/lib/brotli-win32-x86/brotlicommon
C:/users/etcim/Development/vibe.0/lib/brotli-win32-x86/brotlienc
C:/users/etcim/Development/vibe.0/lib/brotli-win32-x86/brotlidec
```

Consequences:

- A clean checkout on any other Windows machine **cannot link** without editing `dub.json`.
- README line: “under Windows you must change the `libs-windows-x86_64` and `libs-windows-x86` paths to your local ones.” That is the documented contract.
- The paths mix three roots: a system OpenSSL install, the author’s clone (`C:/users/etcim/Development/vibe.0`), and a brotli build tree on `F:`.
- **2026-08-14 packaging pass:** `dub.json` now uses `$PACKAGE_DIR/lib/...` (`lflags` `/LIBPATH=` + short lib names). Rebuild blobs with `scripts/build-windows-libs.ps1` (clones sqlite amalgamation, brotli, openssl). Library `versions` include `VibeCustomMain` so `dub build` of vibe-0 itself can compile `appmain.d`. `memutils` is now a declared dependency.

This *was* the primary **green blocker** on this host (absolute paths). Re-run `dub build --compiler=ldc2` after `setenv.ps1`.

## Bundled blobs in `lib/` (not what x64 dub.json uses)

The tree ships prebuilt libraries. They are **not** consistently referenced by the `libs-windows-*` keys.

| Path | Contents |
|------|----------|
| `lib/sqlite3_x64.lib`, `lib/sqlite3_x86.lib` | SQLite import/static libs. x64 key points at `C:/users/etcim/Development/vibe.0/lib/sqlite3_x64` (same filenames, different machine). |
| `lib/libsqlite3.dylib` | macOS SQLite dylib. Not named in `libs-posix` (posix expects system `sqlite3`). |
| `lib/brotli-win32-x86/*.lib` | brotlicommon / dec / enc. **This** tree is what the x86 key almost points at (`C:/users/etcim/.../lib/brotli-win32-x86/...`). |
| `lib/brotli-win64-x64/*.lib` | Same three libs for x64. **Not referenced** by `libs-windows-x86_64` (which uses `F:/Development/brotli/out/installed/lib/...`). |
| `lib/openssl-win32-x86/`, `lib/openssl-win64-x64/` | `libcrypto.lib`, `libssl.lib`, `version.txt`. **Not referenced** by either Windows key (which use `C:/Program Files/OpenSSL/lib/...`). |
| `lib/openssl-build-flags.txt` | Configure line for the bundled OpenSSL: `no-tls1 no-tls1_1 no-tls1_2 … enable-tls1_3 no-shared no-sock …`. The bundled OpenSSL is **TLS 1.3 only**, no sockets, no engines. That matches `createTLSContext` routing TLS 1.3 to OpenSSL and everything else to Botan — but only if you actually *link* these blobs. The `Program Files` install may be a full OpenSSL. **Which OpenSSL you get is path-dependent.** |
| `lib/openssl-license.txt`, `lib/brotli-license.txt` | Third-party licenses. |

`lib/` is therefore a **partial** redistribution of native deps, not the build’s source of truth.

## Implicit / language dependencies

| Dep | How it shows up |
|-----|-----------------|
| D compiler | README / examples assume DUB + a recent DMD/LDC. Agent green command is `ldc2`. No compiler version pin in `dub.json`. Changelog at repo root is still the **upstream** 0.7.23 note (DMD 2.065–2.067). The fork has moved; that file was not rewritten. |
| druntime / Phobos | Fibers, threads, `std.concurrency` (optional via `newStdConcurrency`), sockets, JSON exception type. |
| WinSock | Used by `vibe.core.net` / drivers. `WSAStartup` in `shared static this` only under leftover `VibeLibeventDriver` / `VibeWin32Driver` versions — **not** the libasync path. libasync is assumed to init WinSock itself. Unverified. |
| POSIX threads / dl | Explicit `libs-posix`. |

## License split (`LICENSE.txt`)

MIT for the project (Sönke Ludwig 2012–2015, Etienne Cimon 2014–2023). Exceptions:

| File | License |
|------|---------|
| `source/vibe/data/dom.d` | Boost 1.0 (arsd.dom lineage; comments still say `import arsd.dom`) |
| `source/vibe/data/xml.d` | Boost 1.0 (KXML) |
| `source/vibe/db/pgsql/pgsql.d` | Boost 1.0; docs under PostgreSQL manual’s open license |
| `source/vibe/http/cookiejar_dates.d` | BSD-3 |
| `source/vibe/db/sqlite/sqlite3.d` | Boost 1.0 (vendored d2sqlite3) |
| `source/vibe/data/brotli.d` | Google MIT (C API translation) |
| `source/vibe/daemonize/*` | MIT, author Anton Gushcha / NCrashed (embedded third-party) |

Botan, OpenSSL, libhttp2, libasync, brotli, sqlite native libs carry their own licenses at the dependency / `lib/*-license.txt` layer.

## What official vibe.d would have pulled (absent here)

Not present as DUB deps or source:

- `libevent` / win32 driver / libev
- Diet template compiler / `vibe.templ`
- MongoDB driver
- `vibe.web.rest` (and its OpenAPI-ish generators mentioned in `todo.txt`)
- Official vibe.d’s split packages (`vibe-d:http`, `vibe-d:tls`, …). This fork is a **single** `vibe-0` library.

## Host / green implications

A POSIX green (not attempted here) still needs system `libssl`/`libcrypto`, `libsqlite3`, brotli, a resolvable `botan` + `libasync` + `libhttp2` + `openssl` (patched) from DUB, and `memutils` via the graph.

A Windows green needs, in addition:

1. Those absolute paths rewritten **by the consumer** (or matching directories created).
2. `dub add-local` of the http2-patched openssl + `DeimosOpenSSL_3_0`.
3. A CRT that survives `/nodefaultlib:msvcrt` `/nodefaultlib:vcruntime`.
4. Botan actually building on this compiler (previously blocked).

None of that is done in this clone. **Green remains unverified.**
