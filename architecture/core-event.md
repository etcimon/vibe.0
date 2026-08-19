# Core event loop, tasks, drivers

Pin: `eb51b27` / `v1.2.1`. Loci: `source/vibe/core/core.d` (~1.6k), `driver.d`, `drivers/libasync.d` (~2.1k), `task.d`, `net.d`, `stream.d`, `sync.d`, `file.d`, `concurrency.d`, `connectionpool.d`, `args.d`, `log.d`, `trace.d`.

## Shape

```
app  →  runEventLoop / runTask / listenTCP / openFile / setTimer
              │
              ▼
     vibe.core.core          VibeDriverCore : DriverCore
              │              task pool, idle, workers, signals
              ▼
     vibe.core.driver        getEventDriver() → LibasyncDriver
              │              EventDriver interface (documentary)
              ▼
     drivers/libasync.d      libasync EventLoop (one per V| thread)
                             TCP leftover: recv into a waiting user dest
                             (`m_waitDst` / `m_buffer`); unread-ring only
                             when no slice is waiting (same as eventcore).
              │
              ▼
     OS: IOCP / epoll / kqueue   (inside libasync, not this repo)
```

There is no second backend in this tree. `EventDriver` lists the operations; `setupEventDriver` always `new LibasyncDriver`. `getEventDriver` is typed to `LibasyncDriver`.

## Process / thread construction

See [overview.md](overview.md) §0. Additional facts:

- Thread name prefix `"V|"` is a **hard filter**. `static this` / `static ~this` in `core.d` return immediately for other threads. The daemon thread named `"CmdProcessor"` is also skipped inside `LibasyncDriver` (`isControlThread`).
- Worker threads (`setupWorkerThreads`): one per `threadsPerCPU`, named `"V|Vibe Task Worker #N"`. Started lazily when worker tasks are used (`runWorkerTask` path). Each worker has its own driver / event loop.
- `HTTPServerOption.distribute` passes `TCPListenOptions.distribute` into the driver. The exact accept-handoff into workers was **not fully walked** (unread: distribute path in `libasync.d`).
- Shutdown: main thread sets `st_term`, emits `st_threadsSignal`, `destroyAsyncThreads()`, waits on `st_threadShutdownCondition` for non-daemon threads, then `deleteEventDriver()`. Leftover `s_totalConnections` / `s_totalStreams` / `s_totalSessions` / yielded tasks are `logWarn`’d, including HTTP/2 registry URIs.

## `runEventLoop` / idle / exit

```
runEventLoop:
    s_eventLoopRunning = true
    notifyIdle()                  // drain yield()ed tasks
    if exit already: processEvents(); return
    on main thread: runTask(watchExitFlag)
    getEventDriver().runEventLoop()
```

`LibasyncDriver.runEventLoop`:

```
while (!exitFlag && getEventLoop().loop(-1.seconds)) {
    processTimers();
    getDriverCore().notifyIdle();
}
```

- `loop(-1.seconds)` = block in libasync until an event.
- `loop(0.seconds)` = `processEvents()` (non-blocking poll).
- `runEventLoopOnce` = one blocking wait + timers + idle.

`exitFlag` is `m_break` plus, on Windows (non-unittest), `getExitFlag()` so a Windows service can stop the loop.

`exitEventLoop(shutdown_all_threads)` sets `s_exitEventLoop` and `m_exitSignal.trigger()`. A skip-counter (`m_exitSignalsToSkip`) absorbs signals that raced with a completed iteration.

`setIdleHandler` installs a delegate run from `notifyIdle` when the queue is empty. Returning `true` immediately re-queues idle (busy idle). `VibeIdleCollect` additionally rearms a GC timer from `VibeDriverCore.setupGcTimer` (lightly read).

## Tasks = fibers

`Task` is a `(TaskFiber, taskCounter)` handle. Counter increments on reuse so a stale `Task` compares unequal after the fiber is recycled.

`TaskFiber` extends `core.thread.Fiber`, owns a `MessageQueue` (for `vibe.core.concurrency.send`/`receive`), optional Phobos `Tid`, and a `priority` byte defaulting to **16** (HTTP/2 default weight — a fork-era coupling).

`runTask(dg, args...)`:

- Args must fit `maxTaskParameterSize` (128 bytes combined).
- Recycles `CoreTask` from `s_availableFibers` (capacity grown to 1024) or `ThreadMem.alloc`.
- Emits debugger events (`preStart` / `postStart` / yield / resume) unless `VibeNoDebug`.
- `resumeTask(handle, null, true)` runs the fiber **now** until it yields.

I/O “blocks” by calling `DriverCore.yieldForEvent` / `yieldForEventDeferThrow`. The driver stores the current `Task` on the waiter (reader/writer slot on the TCP object, timer owner, `ManualEvent` wait list) and returns to the event loop. Readiness calls `resumeTask`, optionally with an `Exception` that is thrown into the fiber (`TimeoutException`, `InterruptException`, connection-closed).

`Task.interrupt()` defers to the next wait/yield (changelog 0.7.23 behavior). `InterruptibleTaskMutex` / `InterruptibleTaskCondition` restore the old throw-on-interrupt mutex behavior.

`yield()` (core) pushes the task onto `s_yieldedTasks` and lets idle resume it — cooperative scheduling without an OS event.

## `DriverCore` / `VibeDriverCore`

Interface (`driver.d`): `eventException`, `yieldForEvent`, `yieldForEventDeferThrow`, `resumeTask`, `yieldAndResumeTask`, `notifyIdle`.

`VibeDriverCore` (in `core.d`, not fully line-walked) is the concrete core passed into `LibasyncDriver`. It is the only implementation.

`TimeoutException` lives in `driver.d` (“connection has received no data for Session timeout”). HTTP/2 and HTTP/1 keep-alive both use driver-level wait timeouts.

## libasync driver (the backend)

One `LibasyncDriver` per `"V|"` thread. Fields of note:

- `s_evLoop` thread-local, `gs_evLoop` process first-loop (used if TLS / other code asks before per-thread setup).
- `TimerQueue!TimerInfo` + one `AsyncTimer` for the next expiry. Timers are **not** one OS timer each; they are a heap drained in `processTimers`. A timer either resumes an owner task or `runTask(callback)`.
- `AsyncSignal m_exitSignal` for cross-thread / self exit.
- Manual-event IDs allocated from a global free list (`gs_availID`, `gs_mutex`).

TCP (inbound): `handler(TCPEvent)`:

| Event | Action |
|-------|--------|
| `CONNECT` | inbound → `runTask(&onConnect)`; outbound → `onConnect()` sync |
| `READ` | fill buffer; resume reader task; fall through to WRITE |
| `WRITE` | resume writer task |
| `CLOSE` / `ERROR` | `onClose`; if `onConnect` still set, call it (failed connect) |

`onConnect` runs the listen callback (`handleHTTPConnection` or user TCP handler). Inbound sockets are `close()`d when the callback returns.

File I/O: `openFile` is implemented via `threadedfile` (blocking fds + `yield`), not true async IOCP/`io_uring`. `todo.txt` still says “Asynchronous file I/O (already works for Win32)” — that was the **old** Win32 driver. Unverified whether libasync has a real async file path on this pin; `vibe.core.file` always goes through `getEventDriver().openFile`.

UDP: `listenUDP` → libasync UDP. Example: `examples/udp`.

UDS: `connectUDS` is `version(linux)` on `EventDriver` usage in `net.d`. PostgreSQL and Redis can take `/tmp/.s.PGSQL.*` / `/tmp/redis.sock`. Driver method existence is implied; **not fully read**.

Directory watcher: `watchDirectory` → used by `tests/dirwatcher`. Lightly read.

`NetworkAddress` is libasync’s type, re-exported. DNS: `resolveHost(host, family, use_dns)` can block the fiber on a DNS wait inside the driver.

## Streams and net façade

`vibe.core.stream`: `InputStream`, `OutputStream`, `Stream`, `ConnectionStream`, `Buffered`, `nullSink`. This is the currency of HTTP, TLS, files, SMTP.

`vibe.core.net`:

- `listenTCP` / `connectTCP` / `listenUDP` / `connectUDS` (linux)
- `TCPConnection`: nodelay, keepalive, readTimeout, peer/local/remote addresses
- `TCPListener.stopListening`
- Dual-stack convenience: `listenTCP(port, cb)` tries `"::"` then `"0.0.0.0"` and requires at least one success

## Sync primitives

`vibe.core.sync`: fiber-aware `TaskMutex`, `TaskCondition`, `Interruptible*` variants, `LocalTaskSemaphore` (used by `ConnectionPool.maxConcurrency`), `ManualEvent` (driver-backed, cross-task wake), `ScopedMutexLock`.

Several APIs are `nothrow` to track Phobos `Mutex` (0.7.23). `version(VibeLibevDriver)` still disables some timer-based locks — dead backend.

## Connection pool

`vibe.core.connectionpool.ConnectionPool!T`: factory delegate, vector of conns, lock-count AA, `LocalTaskSemaphore`. `lockConnection()` associates the connection with the current fiber until the `LockedConnection` refcount hits zero. Used by Redis, HTTP client, (intended) proxy. Comment in file: “todo: Fix error in corruption exception”.

## Concurrency / messages

`vibe.core.concurrency`: vibe’s `send`/`receive`/`receiveTimeout` over `Task` message queues, plus interoperability with Phobos `std.concurrency` when `newStdConcurrency`. ~1.1k lines, **not fully read**. `version(EnablePhobosFails)` marks known Phobos mismatches.

## Logging, args, trace

- `vibe.core.log`: diagnostic / info / error / trace levels, console and file loggers, `--vibeLog*` unless `VibeNoDefaultArgs`. `VibeNoStdout` / `VibeWinrtDriver` disable stdout. Initialized from `shared static this` after a `std.stdio` workaround (compiler ctor order).
- `vibe.core.args`: see [build-test.md](build-test.md).
- `vibe.core.trace` + `Trace`/`OnCapture` in `core.d`: CTFE mixins that push a call-stack string onto `TaskDebugger`. `Name!` / `Breadcrumb!` annotate tasks for error pages. Compiled out under `VibeNoDebug`. `vibe.http.debugger.serveAllocations` dumps memutils allocator stats and live HTTP/2 session/stream counts.

## Memory

Design intent (README): avoid GC internally; `memutils` for `ThreadMem`, `ScopedPool`, `Vector`, `HashMap`, `CircularBuffer`, `RefCounted`, `Unique`. HTTP request parse uses a 4 KiB `ScopedPool` frozen around the user handler. TLS “LockMemory” / `SafetyLevel` on HTTP/2 streams tries to keep frame buffers off the pagefile.

This is a **policy**, not a proof. Many Phobos and string operations still allocate. `LogAllocations` exists for hunting leaks.

## Invariants

- Only one driver implementation. Do not document libevent as available.
- Tasks are single-threaded. Passing a `Task` to another thread is supported as a handle (`send`); do not run the fiber on two threads.
- `"V|"` thread naming is required for driver TLS/ctor side effects (e.g. session RNG in `http/session.d` also keys off this prefix).
- `runEventLoop()` is mandatory for a custom `main`.
- File I/O may block a worker-ish path; do not assume it is as cheap as a socket yield.
- `getEventDriver()` asserts if `vibe.core.core`’s module ctor did not run.

## Unread in this file’s scope

- Full `VibeDriverCore` method bodies (idle, GC timer, worker task queue).
- `TCPListenOptions.distribute` accept path.
- `libasync.d` UDP, UDS, file, directory-watcher implementations (only TCP + timers + loop were read in detail).
- `concurrency.d` scheduler edge cases.
- `log.d` format / logger list.
- `drivers/timerqueue.d` internals (interface is clear from use).
