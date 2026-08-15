# Data and databases

Pin: `eb51b27` / `v1.2.1`.

`vibe.data` is JSON + a generic serializer + two vendored document stacks (XML, HTML DOM) + brotli C bindings.  
`vibe.db` is three clients: vendored SQLite wrapper, first-party Redis, standalone PostgreSQL (no libpq).

None of Mongo, Redis-as-required-service, or SQLite are pulled in by the library `dub.json` except the **native** sqlite link name. Modules compile if you import them.

## `vibe.data.json` (~2.0k lines)

Locus: `source/vibe/data/json.d`. Public-imports `vibe.data.serialization`.

`Json` is an 8-byte-aligned tagged value (`Type` enum: undefined/null/bool/int/bigInt/float/string/array/object). Strict typing: operations across types throw `JSONException` (`std.json`’s exception type). Access:

- `j["key"]`, `j[idx]`, `get!T`, `to!T`
- Iteration `foreach (string key, value; j)`
- `toString` / `toPrettyString` / `parseJson` / `parseJsonString`

Versions:

- `VibeJsonFieldNames` — track dotted names for error messages.
- `JsonLineNumbers` — store parse line.
- `JsonOptionalChaining` — missing key/index returns a sentinel instead of throwing.

Member-syntax `j.name = …` is **deprecated** in the module unittests.

HTTP server fills `req.json` when `parseJsonBody` is on and `Content-Type` is `application/json` or `application/vnd.api+json` (reads the whole body as UTF-8).

**Unread:** serializer integration details, BigInt path, pretty-printer edge cases.

## `vibe.data.serialization` (~1.0k)

Policy-based (de)serialization. Rules (module header, still accurate):

1. enums (raw or `@byName`)
2. serializer-native types
3. arrays / `Tuple`
4. AAs (stringish keys)
5. `Nullable!T`
6. `isPolicySerializable` / `isCustomSerializable`
7. `toISOExtString` (e.g. `SysTime`)
8. `toString` / `fromString`
9. struct/class as object (`@name`, `@optional`, `@asArray`)
10. pointers
11. scalars

No aliasing detection (cycles / shared refs become copies). Used by JSON and by Redis session JSON blobs. `examples/serialization` is the sample.

**Unread:** policy API, `@ignore` / `@optional` full set, error paths.

## `vibe.data.xml` (~1.5k) — Boost, KXML

Vendored XML 1.0 parser/writer. Header: William K. Moore / opticron. TODOs in-file (XPath). **Not in the barrel.** Sampled header only — treat as third-party.

## `vibe.data.dom` (~7.2k) — Boost, arsd.dom

Largest file in the tree. HTML DOM with JS-like `querySelector`, `innerHTML`, etc. Comments still say `import arsd.dom`. Optional `arsd.characterencodings` / `version(with_arsd_jsvar)` / `dom_with_events` / `dom_node_indexes` — **not wired** in this package. **Not in the barrel.** **Not line-walked.** README lists “DOM/XML Parsing support” as a fork addition.

## Brotli

Two layers:

| Module | What |
|--------|------|
| `vibe.data.brotli` | `extern(C)` translation of Google’s brotli API (encoder + decoder). MIT. |
| `vibe.stream.brotli` | vibe `Stream` wrapper over that API. Used by **HTTP client** decompress. |

Native libs: POSIX `brotlicommon/dec/enc`; Windows absolute paths (see [dependencies.md](dependencies.md)). HTTP **server** auto-compression is gzip/deflate only.

## `vibe.db.sqlite.sqlite3` (~2.4k) — Boost, d2sqlite3

Vendored [d2sqlite3](https://github.com/biozic/d2sqlite3)-style wrapper. `public import etc.c.sqlite3`. API: `Database`, `Statement`, `Row`, `ColumnData`, `SqliteType`, `versionString`, `threadSafe`. Handles D types + `Nullable!T`.

Not gated by `version(SQLite)` despite README listing that version. Importing the module links `sqlite3` (posix) or the Windows `.lib` named in `libs-windows-*`.

Unittests inside the file expect a working libsqlite (`versionString.startsWith("3.")`). They will fail to *link* on this host for the same path reason as the rest of green.

TLS session persistence via botan’s `TLSSessionManagerSQLite` is **not** this module; it lives in botan and would also need sqlite.

**Unread:** backup API, UDF registration, `SQLITE_ENABLE_COLUMN_METADATA` branch.

## `vibe.db.redis` (~1.4k + extras)

First-party RESP client.

- `connectRedis(host, port=6379)` → `RedisClient` with `ConnectionPool!RedisConnection`.
- `getDatabase(index)` → `RedisDatabase` (commands as methods).
- Pub/sub: `RedisSubscriber` (`examples/redis-pubsub`).
- `sessionstore.RedisSessionStore` implements `vibe.http.session.SessionStore` (hash per session id, optional `expire`).
- `idioms.d`, `types.d` — helpers, **lightly unread**.
- `version(linux)` UDS: `connectRedis("/tmp/redis.sock")` as in the README sample.
- `version(RedisDebug)` logs request/reply.

Auth: `m_authPassword` field exists; AUTH command path **not fully read**.

`examples/redis`, `tests/redis` (stale `vibe-d` dep). Needs a running Redis to be meaningful.

## `vibe.db.pgsql.pgsql` (~2.5k) — Boost, no libpq

Standalone binary-protocol client. Features claimed in the header: prepared statements, enums, arrays, composites, partial parameterized queries. Auth: **cleartext and MD5 only** (no SCRAM). TODOs: BigInt/numeric, geometric, network, bit, UUID, XML, transactions, async notify, memory.

`PostgresDB` takes a `string[string]` param map (`host`, `database`, `user`, `password`, `ssl`, `statement_timeout`, …). `host` may be a Unix socket path on linux (`UDSConnection`). `maxConcurrency` + `lockConnection()` = vibe `ConnectionPool`.

`PGCommand` / query result range: see module examples. SSL: can wrap `TLSStream` (`PGStream` has a TLS ctor). README uses `"ssl": "require"` on Windows.

**Unread:** protocol state machine, type OID map, error recovery, SSL negotiation sequence.

## How the README app uses these

```
RedisSessionStore("localhost", 0)     // HTTP sessions
PostgresDB(params).lockConnection()   // app data
connectRedis(...).getDatabase(0)      // cache
req.json / writeJsonBody              // JSON
```

SQLite is optional infrastructure (TLS session cache, ad-hoc DBs), not on the default HTTP path.

## Invariants

- JSON `Json` is the interchange type for HTTP and Redis sessions; the generic serializer is the typed API.
- DOM/XML are vendored third-party and license-different; do not “style-match” them to vibe when editing.
- SQLite wrapper is always compiled when imported; there is no `version(SQLite)` gate in this tree.
- PostgreSQL is **not** libpq; auth and type coverage are the module header’s, not PostgreSQL’s full surface.
- Redis and Postgres connections are fiber-pooled; do not share a locked connection across tasks.
- Brotli is a **client decode + C binding** story; server `useCompressionIfPossible` will not emit `br`.

## Unread (large)

- `data/dom.d` almost entirely.
- `data/xml.d` almost entirely.
- `data/brotli.d` C API surface (encoder params).
- `stream/brotli.d` stream state machine.
- Most of `pgsql.d` and `sqlite3.d` beyond headers / ctors.
- Redis command coverage and pub/sub teardown.
