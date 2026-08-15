# Build, versions, examples, tests

Pin: `eb51b27` / `v1.2.1`. Green: **verified 2026-08-14** on Windows x64 / LDC 1.42.0 (`dub build` of the library and `examples/http_static_server`). Native libs via `$PACKAGE_DIR/lib` + `scripts/build-windows-libs.ps1`.

## Package recipe (`dub.json`)

| Key | Value |
|-----|--------|
| `name` | `vibe-0` |
| `targetType` | `library` |
| `mainSourceFile` | `source/vibe/appmain.d` |
| `license` | MIT |
| `homepage` | `http://vibed.org/` (upstream leftover) |
| `copyright` | © 2012-2014 Sönke Ludwig (does not mention Etienne; `LICENSE.txt` does) |
| `buildRequirements` | `requireBoundsCheck` |
| `versions` | `Have_vibe_d`, `EnableDebugger` |
| `-ddoxFilterArgs` | hide `vibe.core.drivers.` and `vibe.internal.` |

Authors listed: Sönke Ludwig, Jan Krüger, Matthias Dondorff, Etienne Cimon, “see github for more”.

There is no `configurations` block, no `subPackages`, no `buildTypes` override, no `toolchainRequirements`. One library, all sources under `source/`.

## Default `main` is compile-time dead

`source/vibe/appmain.d`:

```
version (VibeCustomMain) {}
else:
  version (VibeDefaultMain) {}
  else static assert(false, "…VibeDefaultMain is required… Or use VibeCustomMain…");

int main() {
    writeln("Int MAIN");
    static assert(false, "You must place your code in your own main() and cannot use shared static this() using this fork");
    // unreachable: finalizeCommandLineOptions / lowerPrivileges / runEventLoop
}
```

Implications:

- Building the library **without** either version fails the outer `static assert` as soon as `appmain.d` is compiled (and it is the `mainSourceFile`).
- The library’s own `dub.json` does **not** set `VibeCustomMain` or `VibeDefaultMain`. `dub build` of `vibe-0` alone is therefore expected to hit that assert unless the compiler invocation adds a version. **Unverified** (link would fail first on this Windows host).
- Apps must set `VibeCustomMain` and write `main()` that ends in `runEventLoop()`. That is the README contract.
- Apps that set `VibeDefaultMain` and use `shared static this()` (several examples, official vibe.d style) **will not compile** against this fork.

`finalizeCommandLineOptions` / `lowerPrivileges` still exist in `vibe.core.args` / `vibe.core.core`. Custom mains that want the old CLI/`--uid` behavior must call them. README’s sample does not.

## Version matrix used in-tree

See [interface.md](interface.md) for semantics. Where they are set:

| Location | Versions |
|----------|----------|
| library `dub.json` | `Have_vibe_d`, `EnableDebugger` |
| Most examples | `VibeCustomMain` **or** `VibeDefaultMain`, plus `DisableDebugger`, `VibeNoDebug` |
| `examples/http_static_server`, `h2_server` | `VibeCustomMain`, `DisableDebugger`, `VibeNoDebug`, `TLSGC` |
| `examples/h2_request` | `VibeCustomMain`, `EnableDebugger`, `LogAllocations` |
| `examples/https_server` | `VibeDefaultMain`, `Have_vibe_d` — **broken vs fork main()** |
| README sample app | `VibeCustomMain DisableDebugger VibeNoDebug SQLite TLSGC VibeRequestDebugger VibeDebugCatchAll DeimosOpenSSL_3_0` |
| `tests/args`, `redis`, `tcpproxy` | `VibeCustomMain` only; depend on **`vibe-d`** (wrong name) |
| `tests/dirwatcher` | `VibeCustomMain`, `LogAllocations`, `EnableDebugger`; depends on **`vibe-0`** |

`DisableDebugger` and `TLSGC` and `SQLite` are **not** matched by `version(...)` in `source/`. They may be intended for botan / debugger / optional sqlite, but as of this pin they do not gate this tree.

## Examples (`examples/`)

23 apps. Each is its own DUB package depending on `"vibe-0": { "version": "~master", "path": "../../" }`. Several also pass Windows `lflags` (`/verbose:lib`, `/nodefaultlib:msvcrt`).

| Example | Intent | Main style |
|---------|--------|------------|
| `http_static_server` | Static files + gzip precompressed sibling; README’s throughput claim | Custom `main` + `runEventLoop` |
| `https_server` | TLS via `createSSLContext` + cert files | `shared static this` + **DefaultMain** |
| `https_server_sni` | Two certs / hostnames | DefaultMain |
| `h2_server` | HTTP/2 listen on 4343, no TLS in the snippet | Custom |
| `h2_request` | HTTP/2 client to httpbin, Botan/OpenSSL, cookie jar | Custom |
| `http_request` | Client GET | DefaultMain |
| `http_reverse_proxy` | Reverse proxy | DefaultMain |
| `websocket` | WS + static `public/` | DefaultMain |
| `echoserver` | TCP echo | DefaultMain |
| `daytime` | TCP daytime | Custom |
| `udp` | UDP | DefaultMain |
| `tcp_separate` | Split TCP | DefaultMain |
| `download` | `download` / urltransfer | Custom |
| `file_operations` | `vibe.core.file` | DefaultMain |
| `json` | `vibe.data.json` | Custom |
| `serialization` | `vibe.data.serialization` | Custom |
| `message` | inet message | DefaultMain |
| `sendmail` | SMTP | Custom |
| `redis` / `redis-pubsub` | Redis client | Custom / DefaultMain |
| `future` | concurrency helpers | DefaultMain |
| `bench-http-request` / `bench-urlrouter` | Microbenches | (see their `dub.json`) |

`h2_server` and `https_server` ship `server.crt` / `server.key`. `https_server_sni` ships hosta/hostb certs.

**Any example with `VibeDefaultMain` is stale relative to `appmain.d`.** Prefer `http_static_server`, `h2_server`, `h2_request`, `json`, `redis` as living samples.

## Tests (`tests/`)

Four integration-style apps, not a unified `dub test` suite.

| Test | Depends on | Notes |
|------|------------|-------|
| `args/` | **`vibe-d`** path `../../` | `shared static this` + `getOption` + custom `main` that only `finalizeCommandLineOptions`. Has `test.sh`. |
| `dirwatcher/` | `vibe-0` | Directory watcher. |
| `redis/` | **`vibe-d`** | Needs a Redis server. |
| `tcpproxy/` | **`vibe-d`** | TCP proxy. |

Three of four will not resolve this package (DUB name is `vibe-0`). That is leftover from the rename. `CONTRIBUTING.md` still says “run `dub test`” in the **upstream vibe.d** voice.

In-source `unittest` blocks exist (JSON, serialization, router, sqlite, …). `http/test.d` is `version(unittest)` only. No CI config lives in this clone. `todo.txt` is an old vibe.d punch list (Diet, vibedist, nginx compare), not a current test plan.

## Command line / config file

`vibe.core.args`:

- Parses process args via `std.getopt`.
- Optional JSON config `vibe.conf` searched in `.`, home, `/etc/vibe/` (POSIX).
- Built-in options (unless `VibeNoDefaultArgs`): `--uid`/`--user`, `--gid`/`--group` for `lowerPrivileges`.
- `finalizeCommandLineOptions()` must be called or leftover args error. Default `main` used to do this; custom mains often forget.

## Privilege drop

`lowerPrivileges()` (POSIX): `setgid`/`setuid` from the CLI names. No-op if unset. Windows: not applicable. README’s sample does not call it.

## Daemonize

`vibe.daemonize.{daemon,linux,windows,keymap}` embeds NCrashed’s daemonize library (Windows service / Linux daemon). **Not** in the barrel. Lightly read. Windows file is large (~900 lines) and talks to SCM.

## Suggested green (when host deps exist)

Not run here. A plausible sequence, recorded so it is not re-invented:

1. Provide OpenSSL 3 headers/libs and set `DeimosOpenSSL_3_0`.
2. `dub add-local` the http2-patched openssl.
3. Point `libs-windows-*` at **this** machine (or, on POSIX, install sqlite/brotli/ssl).
4. Ensure botan + libasync + libhttp2 + memutils resolve for the chosen compiler.
5. `dub build --compiler=ldc2` in the clone **with** `VibeCustomMain` (otherwise `appmain.d` asserts).
6. Then `dub build` of `examples/http_static_server` (already `VibeCustomMain`).
7. `dub test` is **not** a known-good target; unittests may pull sqlite C and network.

Until steps 1–3 exist on the host, step 5 is blocked. **Do not record a green cell from this notes pass.**

## RISC-V affinity (latent)

This is portable D + C libraries. A RISC-V Linux build would need ldc2/gdc for the target, libasync’s epoll backend, and the POSIX C libs. No RISC-V-specific source. No cross recipe. Unverified; see [open-questions.md](open-questions.md).
