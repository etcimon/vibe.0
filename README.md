vibe.0 is a high-performance asynchronous I/O, concurrency and web application toolkit written in D. It achieves more than 2x higher throughput vs Nginx in benchmarks, using the HTTP static server example at `examples/http_static_server`.

It has forked off Vibe.d in 2015 and shares only the same core, with some additions to make it fully capable of developing mobile, desktop and server applications:

- Integrates with libasync for event loop and networking
- Unix File Sockets
- PostgreSQL support
- DOM/XML Parsing support
- CookieJars
- TLS 1.3 through OpenSSL
- Full Botan crypto suite integration
- Uses memutils for all memory operations
- Thrives to avoid all GC allocations internally
- Daemonize library embedded for launching as background services in windows or daemons in linux
- SQLite integration

It doesn't use @safe, which I believe only makes the code unreadable due to having to use @trusted everywhere.

A working example of 
