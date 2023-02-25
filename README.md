vibe.0 is a high-performance asynchronous I/O, concurrency and web application toolkit written in D.

It has forked off Vibe.d in 2014 and shares only the same core, with some additions to make it fully capable of developing mobile, desktop and server applications:

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