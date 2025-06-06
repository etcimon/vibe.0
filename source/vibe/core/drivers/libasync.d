/**
	Uses libasync

	Copyright: © 2014 Sönke Ludwig, GlobecSys Inc
	Authors: Sönke Ludwig, Etienne Cimon
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
*/
module vibe.core.drivers.libasync;

import vibe.core.core;
import vibe.core.driver;
import vibe.core.drivers.threadedfile;
import vibe.core.log;
import vibe.inet.path;

import libasync;
import libasync.types : Status;

import std.algorithm : min, max;
import std.array;
import std.encoding;
import std.exception;
import std.conv;
import std.string;
import std.typecons;
import std.datetime;
import core.stdc.stdio;

import core.atomic;
import core.memory;
import core.thread;
import core.sync.mutex;
import memutils.utils;
import memutils.vector;
import memutils.circularbuffer;

import vibe.core.drivers.timerqueue;
import std.stdio : File;
import core.atomic;

private __gshared EventLoop gs_evLoop;
private EventLoop s_evLoop;
private DriverCore s_driverCore;

static if (__VERSION__ >= 2071)
    extern (C) bool gc_inFinalizer();

version(Windows) extern(C) {
	FILE* _wfopen(const(wchar)* filename, const wchar* mode);
	int _wchmod(const wchar*, int);
}

EventLoop getEventLoop() nothrow
{
	if (s_evLoop is null)
		return gs_evLoop;

	return s_evLoop;
}

DriverCore getDriverCore() nothrow
{
	assert(s_driverCore !is null);
	return s_driverCore;
}

private struct TimerInfo {
	size_t refCount = 1;
	void delegate() callback;
	Task owner;

	this(void delegate() callback) { this.callback = callback; }
}

/// one per thread
final class LibasyncDriver : EventDriver {
	private {
		bool m_break = false;
		Thread m_ownerThread;
		AsyncTimer m_timerEvent;
		TimerQueue!TimerInfo m_timers;
		SysTime m_nextSched = SysTime.max;
		shared AsyncSignal m_exitSignal;
		shared ushort m_exitSignalsToSkip;
		shared ushort m_exitSignalsPending;

		@property bool exitFlag() {

			version(unittest) return m_break; else
			version(Windows) return m_break || getExitFlag; // accomodate Windows Services
			else return m_break;
		}
	}

	this(DriverCore core) nothrow
	{
		if (isControlThread) return;

		try {
			if (!gs_mutex) {
				import core.sync.mutex;
				gs_mutex = new core.sync.mutex.Mutex;

				gs_availID.reserve(32);

				foreach (i; gs_availID.length .. gs_availID.capacity) {
					gs_availID.insertBack(i + 1);
				}

				gs_maxID = 32;
			}
		}
		catch (Throwable) {
			assert(false, "Couldn't reserve necessary space for available Manual Events");
		}

		m_ownerThread = Thread.getThis();
		s_driverCore = core;
		s_evLoop = getThreadEventLoop();

		if (!gs_evLoop)
			gs_evLoop = s_evLoop;

		m_exitSignal = new shared AsyncSignal(getEventLoop());
		m_exitSignal.run({
				atomicOp!"-="(m_exitSignalsPending, cast(ushort) 1);
				//logTrace("Got exit signal!");
				if (atomicLoad(m_exitSignalsToSkip) > 0) {
					atomicOp!"-="(m_exitSignalsToSkip, cast(ushort) 1);
				} else {
					m_break = true;
				}
			});

		//logTrace("Loaded libasync backend in thread %s", Thread.getThis().name);

	}

	static @property bool isControlThread() nothrow {
		scope(failure) assert(false);
		return Thread.getThis().isDaemon && Thread.getThis().name == "CmdProcessor";
	}

	void dispose() {
		//logTrace("Deleting event driver");
		m_break = true;
		destroyEventWaiters();
		getEventLoop().exit();
		getEventLoop().destroy();
	}

	int runEventLoop()
	{
		while(!exitFlag && getEventLoop().loop(-1.seconds)){
			//logTrace("Regular loop");
			processTimers();
			getDriverCore().notifyIdle();
		}
		if (atomicLoad(m_exitSignalsPending) > 0)
			atomicOp!"+="(m_exitSignalsToSkip, cast(ushort) 1);
		logInfo("Event loop exit %s", exitFlag);
		m_break = false;
		return 0;
	}

	int runEventLoopOnce()
	{
		getEventLoop().loop(-1.seconds);
		//logTrace("runEventLoopOnce");
		processTimers();
		getDriverCore().notifyIdle();

		if (atomicLoad(m_exitSignalsPending) > 0)
			atomicOp!"+="(m_exitSignalsToSkip, cast(ushort) 1);
		//logTrace("runEventLoopOnce exit");
		return 0;
	}

	bool processEvents()
	{
		getEventLoop().loop(0.seconds);
		//logTrace("processEvents");
		processTimers();
		if (atomicLoad(m_exitSignalsPending) > 0)
			atomicOp!"+="(m_exitSignalsToSkip, cast(ushort) 1);
		if (exitFlag) {
			m_break = false;
			return false;
		}
		return true;
	}

	void exitEventLoop()
	{
		logInfo("Exiting (%s)", exitFlag);

		atomicOp!"+="(m_exitSignalsPending, cast(ushort) 1);
		m_exitSignal.trigger();

	}

	version(Windows)
	{
		LibasyncFileStream openFile(Path path, FileMode mode)
		{
			return new LibasyncFileStream(path, mode);
		}
	} else {
		ThreadedFileStream openFile(Path path, FileMode mode)
		{
			return new ThreadedFileStream(path, mode);
		}
	}



	DirectoryWatcher watchDirectory(Path path, bool recursive)
	{
		return new LibasyncDirectoryWatcher(path, recursive);
	}

	/** Resolves the given host name or IP address string. */
	NetworkAddress resolveHost(string host, ushort family = 2, bool use_dns = true)
	{
		mixin(Trace);
		import libasync.types : isIPv6;
		isIPv6 is_ipv6;

		enum : ushort {
			AF_INET = 2,
			AF_INET6 = 23
		}

		if (family == AF_INET6)
			is_ipv6 = isIPv6.yes;
		else
			is_ipv6 = isIPv6.no;

		import std.regex : regex, Captures, Regex, matchFirst, ctRegex;
		import std.traits : ReturnType;

		auto IPv4Regex = regex(`^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)(\.|$)){4}$`, ``);
		auto IPv6Regex = regex(`^([0-9A-Fa-f]{0,4}:){2,7}([0-9A-Fa-f]{1,4}$|((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)(\.|$)){4})$`, ``);
		auto ipv4 = matchFirst(host, IPv4Regex);
		auto ipv6 = matchFirst(host, IPv6Regex);
		if (!ipv4.empty)
		{
			if (!ipv4.empty)
			is_ipv6 = isIPv6.no;
			use_dns = false;
		}
		else if (!ipv6.empty)
		{ // fixme: match host instead?
			is_ipv6 = isIPv6.yes;
			use_dns = false;
		}
		else
		{
			use_dns = true;
		}

		NetworkAddress ret;

		if (use_dns) {
			bool done;
			struct DNSCallback  {
				Task waiter;
				NetworkAddress* address;
				bool* finished;
				void handler(NetworkAddress addr) {
					*address = addr;
					*finished = true;
					if (waiter != Task() && waiter != Task.getThis())
						getDriverCore().resumeTask(waiter);
				}
			}

			DNSCallback* cb = ThreadMem.alloc!DNSCallback();
			cb.waiter = Task.getThis();
			cb.address = &ret;
			cb.finished = &done;

			// todo: remove the shared attribute to avoid GC?
			shared AsyncDNS dns = new shared AsyncDNS(getEventLoop());
			scope(exit) dns.destroy();
			bool success = dns.handler(&cb.handler).resolveHost(host, is_ipv6);
			if (!success || dns.status.code != Status.OK)
				throw new Exception(dns.status.text);
			while(!done && !exitFlag)
				getDriverCore.yieldForEvent();
			if (dns.status.code != Status.OK)
				throw new Exception(dns.status.text);
			enforce(ret != NetworkAddress.init, format("Failed to resolve host: %s", host));
			assert(ret.family != 0);
			//logTrace("Async resolved address %s", ret.toString());
			ThreadMem.free(cb);

			if (ret.family == 0)
				ret.family = family;

			return ret;
		}
		else {
			ret = getEventLoop().resolveIP(host, 0, is_ipv6);
			if (ret.family == 0)
				ret.family = family;
			return ret;
		}

	}

	LibasyncTCPConnection connectTCP(NetworkAddress addr)
	{
		mixin(Trace);
		AsyncTCPConnection conn = new AsyncTCPConnection(getEventLoop());

		LibasyncTCPConnection tcp_connection = new LibasyncTCPConnection(conn, (TCPConnection conn) {
			Task waiter = (cast(LibasyncTCPConnection) conn).m_settings.writer.task;
			if (waiter != Task()) {
				getDriverCore().resumeTask(waiter);
			}
		});
		scope(failure) {
			if (tcp_connection) {
				if (tcp_connection.connected)
					tcp_connection.close();
				tcp_connection.m_settings.writer.task = Task();
			}
		}
		if (Task.getThis() != Task())
			tcp_connection.acquireWriter();

		tcp_connection.m_tcpImpl.conn = conn;
		conn.peer = addr;

		auto tm = createTimer(null);
		scope(exit) {
			stopTimer(tm);
			releaseTimer(tm);
		}
		m_timers.getUserData(tm).owner = Task.getThis();
		rearmTimer(tm, 30.seconds, false);

		enforce(conn.run(&tcp_connection.handler), format("An error occured while starting a new connection: %s", conn.error));
		while (!tcp_connection.connected && tcp_connection.m_tcpImpl.conn !is null
			&& tcp_connection.m_tcpImpl.conn.status.code == Status.ASYNC && !tcp_connection.m_error && isTimerPending(tm))
			getDriverCore().yieldForEvent();
		enforce(!tcp_connection.m_error, tcp_connection.m_error);
		enforce!ConnectionClosedException(tcp_connection.connected, "Could not connect");
		tcp_connection.m_tcpImpl.localAddr = conn.local;

		if (Task.getThis() != Task())
			tcp_connection.releaseWriter();
		return tcp_connection;
	}

	version(linux) LibasyncUDSConnection connectUDS(string path)
	{
		mixin(Trace);
		UnixAddress addr = new UnixAddress(path.dup);
		AsyncUDSConnection conn = new AsyncUDSConnection(getEventLoop());
		Task waiter = Task.getThis();
		LibasyncUDSConnection uds_connection = new LibasyncUDSConnection(conn, (UDSConnection conn) {
				getDriverCore().resumeTask(waiter);
			});
		scope(failure) {
			if (uds_connection) {
				if (uds_connection.connected)
					uds_connection.close();
			}
		}
		uds_connection.m_udsImpl.conn = conn;
		conn.peer = addr;
		enforce(conn.run(&uds_connection.handler), format("An error occured while starting a new UDS connection: %s", conn.error));
		getDriverCore().yieldForEvent();
		enforce(!uds_connection.m_error, uds_connection.m_error);

		return uds_connection;
	}


	LibasyncTCPListener listenTCP(ushort port, void delegate(TCPConnection conn) conn_callback, string address, TCPListenOptions options)
	{
		NetworkAddress localaddr = getEventDriver().resolveHost(address);
		localaddr.port = port;

		return new LibasyncTCPListener(localaddr, conn_callback, options);
	}

	LibasyncUDPConnection listenUDP(ushort port, string bind_address = "0.0.0.0")
	{
		NetworkAddress localaddr = getEventDriver().resolveHost(bind_address);
		localaddr.port = port;
		AsyncUDPSocket sock = new AsyncUDPSocket(getEventLoop());
		sock.local = localaddr;
		auto udp_connection = new LibasyncUDPConnection(sock);
		if (!sock.run(&udp_connection.handler))
			throw new Exception(format("Cannot listen to %s:%d: %s", bind_address, port, sock.error));
		return udp_connection;
	}

	LibasyncManualEvent createManualEvent()
	{
		return new LibasyncManualEvent(this);
	}

	FileDescriptorEvent createFileDescriptorEvent(int file_descriptor, FileDescriptorEvent.Trigger triggers)
	{
		assert(false);
	}


	// The following timer implementation was adapted from the equivalent in libevent2.d

	size_t createTimer(void delegate() callback) { auto tmid = m_timers.create(TimerInfo(callback)); return tmid; }

	void acquireTimer(size_t timer_id) { m_timers.getUserData(timer_id).refCount++; }
	void releaseTimer(size_t timer_id)
	{

        static if (__VERSION__ >= 2071)
    		assert(gc_inFinalizer() || m_ownerThread is Thread.getThis());
		//logTrace("Releasing timer %s", timer_id);
		if (!--m_timers.getUserData(timer_id).refCount) {
			m_timers.destroy(timer_id);
		}
	}

	bool isTimerPending(size_t timer_id) { return m_timerEvent !is null && m_timers.isPending(timer_id); }

	void rearmTimer(size_t timer_id, Duration dur, bool periodic)
	{
        static if (__VERSION__ >= 2071)
    		assert(gc_inFinalizer() || m_ownerThread is Thread.getThis());
		if (!isTimerPending(timer_id)) acquireTimer(timer_id);
		m_timers.schedule(timer_id, dur, periodic);
		rescheduleTimerEvent(Clock.currTime(UTC()));
	}

	void stopTimer(size_t timer_id)
	{
		//logTrace("Stopping timer %s", timer_id);
		if (m_timers.isPending(timer_id)) {
			m_timers.unschedule(timer_id);
			releaseTimer(timer_id);
		}
	}

	void waitTimer(size_t timer_id)
	{
		mixin(Trace);
		//logTrace("Waiting for timer in %s", Task.getThis());
        static if (__VERSION__ >= 2071)
            assert(gc_inFinalizer() || m_ownerThread is Thread.getThis());
		while (true) {
			assert(!m_timers.isPeriodic(timer_id), "Cannot wait for a periodic timer.");
			if (!m_timers.isPending(timer_id)) {
				// //logTrace("Timer is not pending");
				return;
			}
			auto data = &m_timers.getUserData(timer_id);
			assert(data.owner == Task.init, "Waiting for the same timer from multiple tasks is not supported.");
			data.owner = Task.getThis();
			scope (exit) m_timers.getUserData(timer_id).owner = Task.init;
			getDriverCore().yieldForEvent();
		}
	}

	/// If the timer has an owner, it will resume the task.
	/// if the timer has a callback, it will run a new task.
	private void processTimers()
	{
		if (!m_timers.anyPending) return;
		m_nextSched = SysTime.max;
		// process all timers that have expired up to now
		auto now = Clock.currTime(UTC());

		m_timers.consumeTimeouts(now, (timer, periodic, ref data) {
			Task owner = data.owner;
			auto callback = data.callback;

			//logTrace("Timer %s fired (%s/%s)", timer, owner != Task.init, callback !is null);

			if (!periodic) releaseTimer(timer);

			if (owner && owner.running && owner != Task.getThis()) {
				if (Task.getThis == Task.init) getDriverCore().resumeTask(owner);
				else getDriverCore().yieldAndResumeTask(owner);
			}
			if (callback) runTask(callback);
		});

		rescheduleTimerEvent(now);
	}

	private void rescheduleTimerEvent(SysTime now)
	{
		//logTrace("Rescheduling timer event %s", Task.getThis());

		// don't bother scheduling, the timers will be processed before leaving for the event loop
		if (m_nextSched <= Clock.currTime(UTC()))
			return;
		bool first;
		auto next = m_timers.getFirstTimeout();
		Duration dur;
		if (next == SysTime.max) return;
		import std.algorithm : max;
		dur = max(1.msecs, next - now);
		if (m_nextSched != next)
			m_nextSched = next;
		else return;
		if (dur.total!"seconds"() >= int.max)
			return; // will never trigger, don't bother
		if (!m_timerEvent) {
			//logTrace("creating new async timer for %d ms", dur.total!"msecs");
			m_timerEvent = new AsyncTimer(getEventLoop());
			bool success = m_timerEvent.duration(dur).run(&onTimerTimeout);
			assert(success, "Failed to run timer");
		}
		else {
			//logTrace("rearming the same timer instance for %d ms", dur.total!"msecs");
			bool success = m_timerEvent.rearm(dur);
			assert(success, format("Failed to rearm timer for: %d ms : %s: %s", dur.total!"msecs", m_timerEvent.status.text, m_timerEvent.error));
		}
		//logTrace("Rescheduled timer event for %s seconds in thread '%s' :: task '%s'", dur.total!"usecs" * 1e-6, Thread.getThis().name, Task.getThis());
	}

	private void onTimerTimeout()
	{
		import std.encoding : sanitize;

		//logTrace("timer event fired");
		try processTimers();
		catch (Exception e) {
			logError("Failed to process timers: %s", e.msg);
			try logDiagnostic("Full error: %s", e.toString().sanitize); catch(Throwable) {}
		}
	}
}


final class LibasyncFileStream : FileStream {

	private {
		Path m_path;
		ulong m_size;
		ulong m_offset = 0;
		FileMode m_mode;
		Task m_task;
		Exception m_ex;
		shared AsyncFile m_impl;

		bool m_started;
		bool m_truncated;
		bool m_finished;
	}

	this(Path path, FileMode mode)
	{
		import std.file : getSize,exists;
		if (mode != FileMode.createTrunc) {
			bool success;
			int tries;
			do {
				try {
					m_size = getSize(path.toNativeString());
					success = true;
				} catch (Exception e) {
					if (++tries == 3) throw e;
					sleep(50.msecs);
				}
			} while (!success && tries < 3);
		}
		else {
			auto path_str = path.toNativeString();
			if (exists(path_str))
				removeFile(path);
			{ // touch
				import std.string : toStringz;
				version(Windows) {
					import std.utf : toUTF16z;
					auto path_str_utf = path_str.toUTF16z();
					FILE* f = _wfopen(path_str_utf, "w");
					_wchmod(path_str_utf, S_IREAD|S_IWRITE);
				}
				else FILE * f = fopen(path_str.toStringz, "w");
				if (f)
					fclose(f);
				m_truncated = true;
			}
		}
		m_path = path;
		m_mode = mode;

		m_impl = new shared AsyncFile(getEventLoop());
		m_impl.onReady(&handler);

		m_started = true;
	}

	~this()
	{
		try close(); catch (Throwable) {}
	}

	@property Path path() const { return m_path; }
	@property bool isOpen() const { return m_started; }
	@property ulong size() const { return m_size; }
	@property bool readable() const { return m_mode != FileMode.append; }
	@property bool writable() const { return m_mode != FileMode.read; }

	void seek(ulong offset)
	{
		m_offset = offset;
	}

	ulong tell() { return m_offset; }

	void close()
	{
		if (m_impl) {
			m_impl.kill();
			m_impl = null;
		}
		m_started = false;
		if (m_task != Task() && Task.getThis() != Task())
			getDriverCore().yieldAndResumeTask(m_task, new ConnectionClosedException("The file was closed during an operation"));
		else if (m_task != Task() && Task.getThis() == Task())
			getDriverCore().resumeTask(m_task, new ConnectionClosedException("The file was closed during an operation"));

	}

	@property bool empty() const { assert(this.readable); return m_offset >= m_size; }
	@property ulong leastSize() const { assert(this.readable); return m_size - m_offset; }
	@property bool dataAvailableForRead() { return true; }

	const(ubyte)[] peek()
	{
		return null;
	}

	void read(ubyte[] dst)
	{
		mixin(Trace);
		scope(failure) {
			logError("Failure in file stream");
			close();
		}
		assert(this.readable, "To read a file, it must be opened in a read-enabled mode.");
		shared ubyte[] bytes = cast(shared) dst;
		bool truncate_if_exists;
		if (!m_truncated && m_mode == FileMode.createTrunc) {
			truncate_if_exists = true;
			m_truncated = true;
			m_size = 0;
		}
		m_finished = false;
		enforce(dst.length <= leastSize);
		enforce(m_impl.read(m_path.toNativeString(), bytes, m_offset, true, truncate_if_exists), format("Failed to read data from disk: %s", m_impl.error));

		if (!m_finished) {
			acquire();
			scope(exit) release();
			getDriverCore().yieldForEvent();
		}
		m_finished = false;

		if (m_ex) throw m_ex;

		m_offset += dst.length;
		assert(m_impl.offset == m_offset, format("Incoherent offset returned from file reader: %d B assumed but the implementation is at: %d B", m_offset, m_impl.offset.to!string));
	}

	alias Stream.write write;
	void write(in ubyte[] bytes_)
	{
		assert(this.writable, "To write to a file, it must be opened in a write-enabled mode.");
		mixin(Trace);

		shared const(ubyte)[] bytes = cast(shared const(ubyte)[]) bytes_;

		bool truncate_if_exists;
		if (!m_truncated && m_mode == FileMode.createTrunc) {
			truncate_if_exists = true;
			m_truncated = true;
			m_size = 0;
		}
		m_finished = false;

		if (m_mode == FileMode.append)
			enforce(m_impl.append(m_path.toNativeString(), cast(shared ubyte[]) bytes, true, truncate_if_exists), format("Failed to write data to disk: %s", m_impl.error));
		else
			enforce(m_impl.write(m_path.toNativeString(), bytes, m_offset, true, truncate_if_exists), format("Failed to write data to disk: %s", m_impl.error));

		if (!m_finished) {
			acquire();
			scope(exit) release();
			getDriverCore().yieldForEvent();
		}
		m_finished = false;

		if (m_ex) throw m_ex;

		if (m_mode == FileMode.append) {
			m_size += bytes.length;
		}
		else {
			m_offset += bytes.length;
			if (m_offset >= m_size)
				m_size += m_offset - m_size;
			assert(m_impl.offset == m_offset, "Incoherent offset returned from file writer.");
		}
		//assert(getSize(m_path.toNativeString()) == m_size, "Incoherency between local size and filesize: " ~ m_size.to!string ~ "B assumed for a file of size " ~ getSize(m_path.toNativeString()).to!string ~ "B");
	}

	void write(InputStream stream, ulong nbytes = 0)
	{
		mixin(Trace);
		writeDefault(stream, nbytes);
	}

	void flush()
	{
		assert(this.writable, "To write to a file, it must be opened in a write-enabled mode.");

	}

	void finalize()
	{
		if (this.writable)
			flush();
	}

	void release()
	{
		assert(Task.getThis() == Task() || m_task == Task.getThis(), "Releasing FileStream that is not owned by the calling task.");
		m_task = Task();
	}

	void acquire()
	{
		assert(Task.getThis() == Task() || m_task == Task(), "Acquiring FileStream that is already owned.");
		m_task = Task.getThis();
	}

	private void handler() {
		// This will probably be called by a remote thread, so we use a manual event
		Exception ex;

		if (m_impl.status.code != Status.OK)
			ex = new Exception(m_impl.error);
		m_finished = true;
		if (m_task != Task())
			getDriverCore().resumeTask(m_task, ex);
		else m_ex = ex;
	}
}


final class LibasyncDirectoryWatcher : DirectoryWatcher {
	private {
		Path m_path;
		bool m_recursive;
		Task m_task;
		AsyncDirectoryWatcher m_impl;
		Vector!DirectoryChange m_changes;
		Exception m_error;
	}

	this(Path path, bool recursive)
	{
		m_impl = new AsyncDirectoryWatcher(getEventLoop());
		m_impl.run(&handler);
		m_path = path;
		m_recursive = recursive;
		watch(path, recursive);
		// //logTrace("DirectoryWatcher called with: %s", path.toNativeString());
	}

	~this()
	{
		if (m_impl) m_impl.kill();
	}

	@property Path path() const { return m_path; }
	@property bool recursive() const { return m_recursive; }

	void release()
	{
		assert(m_task == Task.getThis(), "Releasing FileStream that is not owned by the calling task.");
		m_task = Task();
	}

	void acquire()
	{
		assert(m_task == Task(), "Acquiring FileStream that is already owned.");
		m_task = Task.getThis();
	}

	bool amOwner()
	{
		return m_task == Task.getThis();
	}

	bool readChanges(ref DirectoryChange[] dst, Duration timeout)
	{
		mixin(Trace);
		dst.length = 0;
		assert(!amOwner());
		if (m_error)
			throw m_error;
		acquire();
		scope(exit) release();
		void consumeChanges() {
			if (m_impl.status.code == Status.ERROR) {
				throw new Exception(m_impl.error);
			}

			foreach (ref change; m_changes[]) {
				//logTrace("Adding change: %s", change.to!string);
				dst ~= change;
			}

			//logTrace("Consumed change 1: %s", dst.to!string);
			import std.array : array;
			import std.algorithm : uniq;
			dst = cast(DirectoryChange[]) uniq!((a, b) => a.path == b.path && a.type == b.type)(dst).array;
			//logTrace("Consumed change: %s", dst.to!string);
			m_changes.clear();
		}

		if (!m_changes.empty) {
			consumeChanges();
			return true;
		}

		auto tm = getEventDriver().createTimer(null);
		getEventDriver().m_timers.getUserData(tm).owner = Task.getThis();
		getEventDriver().rearmTimer(tm, timeout, false);
		scope(exit) {
			getEventDriver().stopTimer(tm);
			getEventDriver().releaseTimer(tm);
		}
		while (m_changes.empty) {
			getDriverCore().yieldForEvent();
			if (!getEventDriver().isTimerPending(tm)) break;
		}

		if (!m_changes.empty) {
			consumeChanges();
			return true;
		}

		return false;
	}

	private void watch(Path path, bool recursive) {
		m_impl.watchDir(path.toNativeString(), DWFileEvent.ALL, recursive);
	}

	private void handler() {
		import std.stdio;
		DWChangeInfo[] changes = ThreadMem.alloc!(DWChangeInfo[])(128);
		scope(exit) ThreadMem.free(changes);
		Exception ex;
		try {
			uint cnt;
			do {
				cnt = m_impl.readChanges(changes);
				size_t i;
				foreach (DWChangeInfo change; changes) {
					DirectoryChange dc;

					final switch (change.event){
						case DWFileEvent.CREATED: dc.type = DirectoryChangeType.added; break;
						case DWFileEvent.DELETED: dc.type = DirectoryChangeType.removed; break;
						case DWFileEvent.MODIFIED: dc.type = DirectoryChangeType.modified; break;
						case DWFileEvent.MOVED_FROM: dc.type = DirectoryChangeType.removed; break;
						case DWFileEvent.MOVED_TO: dc.type = DirectoryChangeType.added; break;
						case DWFileEvent.ALL: break; // impossible
						case DWFileEvent.ERROR: throw new Exception(m_impl.error);
					}

					dc.path = Path(change.path);
					//logTrace("Inserted %s absolute %s", dc.to!string, dc.path.absolute.to!string);
					m_changes.insert(dc);
					i++;
					if (cnt == i) break;
				}
			} while(cnt == 0 && m_impl.status.code == Status.OK);
			if (m_impl.status.code == Status.ERROR) {
				ex = new Exception(m_impl.error);
			}

		}
		catch (Exception e) {
			ex = e;
		}
		if (m_task != Task()) getDriverCore().resumeTask(m_task, ex);
		else m_error = ex;
	}

}

align(8)
final class LibasyncManualEvent : ManualEvent {
	private {
		shared(int) m_emitCount = 0;
		shared(int) m_threadCount = 0;
		shared(uint) m_instance;
		Vector!(void*, Malloc) ms_signals;
		Vector!(Task, Malloc) m_localWaiters;
		Thread m_owner;
		core.sync.mutex.Mutex m_mutex;

		@property uint instanceID() { synchronized(m_mutex) return m_instance; }
		@property void instanceID(uint instance) { synchronized(m_mutex) m_instance = instance; }
	}

	this(LibasyncDriver driver)
	{
		m_mutex = new core.sync.mutex.Mutex;
		instanceID = generateID() - 1;
	}

	~this()
	{
		try {
			uint instance_id;
			if (gc_inFinalizer())
				instance_id = cast(uint)m_instance;
			else instance_id = instanceID;
			recycleID(instance_id + 1);

			foreach (ref signal; ms_signals[]) {
				if (signal) {
					(cast(shared AsyncSignal) signal).kill();
					signal = null;
				}
			}
		} catch (Throwable) {}
	}

	void emitLocal()
	{
		if (!m_owner) return;
		assert(m_owner == Thread.getThis());
		foreach (Task t; m_localWaiters[])
			resumeLocal(t);
		m_localWaiters.clear();
		m_owner = Thread.init;
	}

	void waitLocal()
	{
		mixin(Trace);
		if (m_localWaiters.length > 0)
			assert(m_owner == Thread.getThis());
		else m_owner = Thread.getThis();
		m_localWaiters.insertBack(Task.getThis());
		getDriverCore().yieldForEvent();
	}

	void waitLocal(Duration timeout)
	{
		mixin(Trace);
		if (m_localWaiters.length > 0)
			assert(m_owner == Thread.getThis());
		else m_owner = Thread.getThis();

		auto tm = getEventDriver().createTimer(null);
		getEventDriver().m_timers.getUserData(tm).owner = Task.getThis();
		getEventDriver().rearmTimer(tm, timeout, false);
		scope (exit) getEventDriver().releaseTimer(tm);

		m_localWaiters.insertBack(Task.getThis());
		getDriverCore().yieldForEvent();
	}

	void emit()
	{
		assert(m_owner is Thread.init);
		try {
			//logTrace("Emitting signal");
			atomicOp!"+="(m_emitCount, 1);
			synchronized (m_mutex) {
				//logTrace("Looping signals. found: %d", ms_signals.length);
				foreach (ref signal; ms_signals[]) {
					auto evloop = getEventLoop();
					//logTrace("Got event loop: %s", cast(void*) evloop);
					shared AsyncSignal sig = cast(shared AsyncSignal) signal;
					if (!sig.trigger(evloop)) logError("Failed to trigger ManualEvent: %s", sig.error);
				}
			}
		} catch(Throwable thr) {
			logDebug("emit failed: %s", thr.toString());
			assert(false);
		}
	}

	void wait() { wait(m_emitCount); }
	int wait(int reference_emit_count) { return  doWait!true(reference_emit_count); }
	int wait(Duration timeout, int reference_emit_count) { return doWait!true(timeout, reference_emit_count); }
	int waitUninterruptible(int reference_emit_count) { return  doWait!false(reference_emit_count); }
	int waitUninterruptible(Duration timeout, int reference_emit_count) { return doWait!false(timeout, reference_emit_count); }

	void acquire()
	{
		assert(m_owner is Thread.init);
		auto task = Task.getThis();

		bool signal_exists;
		uint instance = instanceID;
		if (s_eventWaiters.length <= instance)
			expandWaiters();

		//logTrace("Acquire event ID#%d", instance);
		auto taskList = s_eventWaiters[instance][];
		if (taskList.length > 0)
			signal_exists = true;

		if (!signal_exists) {
			shared AsyncSignal sig = new shared AsyncSignal(getEventLoop());
			sig.run(&onSignal);
			synchronized (m_mutex) ms_signals.insertBack(cast(void*)sig);
		}
		s_eventWaiters[instance].insertBack(Task.getThis());
	}

	void release()
	{
		assert(amOwner(), "Releasing non-acquired signal.");

		import std.algorithm : countUntil;
		uint instance = instanceID;
		auto taskList = s_eventWaiters[instance][];
		auto idx = taskList[].countUntil!((a, b) => a == b)(Task.getThis());
		//logTrace("Release event ID#%d", instance);
		auto vec = taskList[0 .. idx];
		if (idx != taskList.length - 1)
			vec ~= taskList[idx + 1 .. $];
		s_eventWaiters[instance].destroy();
		s_eventWaiters[instance] = vec;
		if (s_eventWaiters[instance].empty) {
			removeMySignal();
		}
	}

	bool amOwner()
	{
		import std.algorithm : countUntil;
		uint instance = instanceID;
		if (s_eventWaiters.length <= instance) return false;
		auto taskList = s_eventWaiters[instance][];
		if (taskList.length == 0) return false;

		auto idx = taskList[].countUntil!((a, b) => a == b)(Task.getThis());

		return idx != -1;
	}

	@property int emitCount() const { return atomicLoad(m_emitCount); }

	private int doWait(bool INTERRUPTIBLE)(int reference_emit_count)
	{
		mixin(Trace);
		static if (!INTERRUPTIBLE) scope (failure) assert(false); // still some function calls not marked nothrow
		assert(!amOwner());
		acquire();
		scope(exit) release();
		auto ec = this.emitCount;
		while( ec == reference_emit_count ){
			//synchronized(m_mutex) //logTrace("Waiting for event %s with signal count: %d", (cast(void*)this).to!string, ms_signals.length);
			static if (INTERRUPTIBLE) getDriverCore().yieldForEvent();
			else getDriverCore().yieldForEventDeferThrow();
			ec = this.emitCount;
		}
		return ec;
	}

	private int doWait(bool INTERRUPTIBLE)(Duration timeout, int reference_emit_count)
	{
		mixin(Trace);
		static if (!INTERRUPTIBLE) scope (failure) assert(false); // still some function calls not marked nothrow
		assert(!amOwner());
		acquire();
		scope(exit) release();
		auto tm = getEventDriver().createTimer(null);
		scope (exit) {
			getEventDriver().stopTimer(tm);
			getEventDriver().releaseTimer(tm);
		}
		getEventDriver().m_timers.getUserData(tm).owner = Task.getThis();
		getEventDriver().rearmTimer(tm, timeout, false);

		auto ec = this.emitCount;
		while (ec == reference_emit_count) {
			static if (INTERRUPTIBLE) getDriverCore().yieldForEvent();
			else getDriverCore().yieldForEventDeferThrow();
			ec = this.emitCount;
			if (!getEventDriver().isTimerPending(tm)) break;
		}
		return ec;
	}

	private void removeMySignal() {
		import std.algorithm : countUntil;
		synchronized(m_mutex) {
			auto idx = ms_signals[].countUntil!((void* a, LibasyncManualEvent b) { return ((cast(shared AsyncSignal) a).owner == Thread.getThis() && this is b);})(this);
			if (idx > ms_signals.length) return;
			auto vec = ms_signals[0 .. idx];
			if (idx != ms_signals.length-1)
				vec ~= ms_signals[idx + 1 .. $];
			ms_signals.destroy();
			ms_signals = vec;
		}
	}

	private void expandWaiters() {
		uint maxID;
		synchronized(gs_mutex) maxID = gs_maxID;
		s_eventWaiters.reserve(maxID);
		//logTrace("gs_maxID: %d", maxID);
		size_t s_ev_len = s_eventWaiters.length;
		size_t s_ev_cap = s_eventWaiters.capacity;
		if (maxID <= s_eventWaiters.length)
		{
			logError("Expanding from %d to %d for maxID: %d, m_instance: %d", s_eventWaiters.length, s_eventWaiters.capacity, maxID, instanceID);
			assert(0);
		}
		foreach (i; s_ev_len .. s_ev_cap) {
			Vector!(Task, ThreadMem) waiter_tasks;
			waiter_tasks.reserve(4);
			s_eventWaiters.insertBack(waiter_tasks.move());
		}
	}

	private void onSignal()
	{
		//logTrace("Got signal in onSignal");
		try {
			auto core = getDriverCore();
			uint instance = instanceID;
			//logTrace("Got context: %d", instance);
			foreach (Task task; s_eventWaiters[instance][]) {
				//logTrace("Task Found");
				core.resumeTask(task);
			}
		} catch (Exception e) {
			logError("Exception while handling signal event: %s", e.msg);
			try logDebug("Full error: %s", sanitize(e.msg));
			catch (Exception) {}
		}
	}
}

final class LibasyncTCPListener : TCPListener {
	private {
		NetworkAddress m_local;
		void delegate(TCPConnection conn) m_connectionCallback;
		TCPListenOptions m_options;
		AsyncTCPListener[] m_listeners;
		fd_t socket;
	}

	this(NetworkAddress addr, void delegate(TCPConnection conn) connection_callback, TCPListenOptions options)
	{
		m_connectionCallback = connection_callback;
		m_options = options;
		m_local = addr;
		void function(shared LibasyncTCPListener, shared TCPListenOptions) init = (shared LibasyncTCPListener ctxt, shared TCPListenOptions _options){
			synchronized(ctxt) {
				LibasyncTCPListener ctxt2 = cast(LibasyncTCPListener)ctxt;
				AsyncTCPListener listener = new AsyncTCPListener(getEventLoop(), ctxt2.socket);
				if ((cast(TCPListenOptions)_options) & TCPListenOptions.tcpNoDelay)
					listener.noDelay = true;
				listener.local = ctxt2.m_local;

				enforce(listener.run(&ctxt2.initConnection), format("Failed to start listening to local socket: %s", listener.error));
				ctxt2.socket = listener.socket;
				ctxt2.m_listeners ~= listener;
			}
		};
		if (options & TCPListenOptions.distribute)	runWorkerTaskDist(init, cast(shared) this, cast(shared) options);
		else init(cast(shared) this, cast(shared) options);

	}

	@property void delegate(TCPConnection) connectionCallback() { return m_connectionCallback; }

	private void delegate(TCPEvent) initConnection(AsyncTCPConnection conn) {
		//logTrace("Connection initialized in thread: " ~ Thread.getThis().name);

		LibasyncTCPConnection native_conn = new LibasyncTCPConnection(conn, m_connectionCallback);
		native_conn.m_tcpImpl.conn = conn;
		native_conn.m_tcpImpl.localAddr = m_local;
		return &native_conn.handler;
	}

	void stopListening()
	{
		synchronized(this) {
			foreach (listener; m_listeners) {
				listener.kill();
				listener = null;
			}
		}
	}
}



final class LibasyncTCPConnection : TCPConnection, Buffered, CountedStream {

	private {
		Thread m_owner;
		CircularBuffer!ubyte m_readBuffer;
		ubyte[] m_buffer;
		ubyte[] m_slice;
		TCPConnectionImpl m_tcpImpl;
		Settings m_settings;
		string m_error;
		bool m_closed = true;
		bool m_mustRecv = true;
		ulong m_bytesRecv;
		ulong m_bytesSend;
		// The socket descriptor is unavailable to motivate low-level/API feature additions
		// rather than high-lvl platform-dependent hacking
		// fd_t socket;
	}

	static @property ulong totalConnections() { return s_totalConnections; }

	ubyte[] readBuf(ubyte[] buffer = null)
	{
		mixin(Trace);
		//logTrace("readBuf TCP: %d", buffer.length);
		import std.algorithm : swap;
		ubyte[] ret;

		if (m_slice.length > 0) {

			swap(ret, m_slice);
			//logTrace("readBuf returned instantly with slice length: %d", ret.length);
			m_bytesRecv += ret.length;
			return ret;
		}

		if (m_readBuffer.length > 0)
		{
			size_t amt = min(buffer.length, m_readBuffer.length);
			m_readBuffer.read(buffer[0 .. amt]);
			//logTrace("readBuf returned with existing amount: %d", amt);
			m_bytesRecv += amt;
			return buffer[0 .. amt];
		}

		if (buffer) {
			m_buffer = buffer;
			destroy(m_readBuffer);
		}

		enforce!ConnectionClosedException(leastSize() > 0, "Leastsize returned 0");

		swap(ret, m_slice);
		//logTrace("readBuf returned with buffered length: %d", ret.length);
		m_bytesRecv += ret.length;
		return ret;
	}

	this(AsyncTCPConnection conn, void delegate(TCPConnection) cb)
	in { assert(conn !is null); }
	do {
		s_totalConnections++;
		m_owner = Thread.getThis();
		m_settings.onConnect = cb;
		m_readBuffer.capacity = 32*1024;
	}

	~this() {
		if (!m_closed) {
			try onClose(null, false);
			catch (Exception e)
			{
				logError("Failure in TCPConnection dtor: %s", e.msg);
			}
		}
	}

	private @property AsyncTCPConnection conn() {

		return m_tcpImpl.conn;
	}

	// Using this setting completely disables the internal buffers as well
	@property void tcpNoDelay(bool enabled)
	{
		if (!conn) return;
		m_settings.tcpNoDelay = enabled;
		conn.setOption(TCPOption.NODELAY, enabled);
	}

	@property bool tcpNoDelay() const { return m_settings.tcpNoDelay; }

	@property void readTimeout(Duration dur)
	{
		m_settings.readTimeout = dur;
		conn.setOption(TCPOption.TIMEOUT_RECV, dur);
	}

	@property Duration readTimeout() const { return m_settings.readTimeout; }

	@property void keepAlive(bool enabled)
	{
		m_settings.keepAlive = enabled;
		conn.setOption(TCPOption.KEEPALIVE_ENABLE, enabled);
	}

	@property bool keepAlive() const { return m_settings.keepAlive; }

	@property bool connected() const {
		return !m_closed && m_tcpImpl.conn !is null && m_tcpImpl.conn.isConnected;
	}

	@property bool dataAvailableForRead(){
		//logTrace("dataAvailableForRead TCP");
		acquireReader();
		scope(exit) releaseReader();
		return !readEmpty;
	}

	private @property bool readEmpty() {
		return (m_buffer && (!m_slice || m_slice.length == 0)) || (!m_buffer && m_readBuffer.empty);
	}

    private string m_peer_addr;

	@property string peerAddress() const {
		enforce!ConnectionClosedException(m_tcpImpl.conn, "No Peer Address");

        if (!m_peer_addr)
            (cast()this).m_peer_addr = m_tcpImpl.conn.peer.toString();
        return m_peer_addr;
	}

	@property NetworkAddress localAddress() const { return m_tcpImpl.localAddr; }
	@property NetworkAddress remoteAddress() const { return m_tcpImpl.conn.peer; }

	@property bool empty() { return leastSize == 0; }

	/// Returns total amount of bytes received with this connection
	@property ulong received() const {
		return m_bytesRecv;
	}

	/// Returns total amount of bytes sent with this connection
	@property ulong sent() const {
		return m_bytesSend;
	}

	@property ulong leastSize()
	{
		mixin(Trace);
		//logTrace("leastSize TCP");
		acquireReader();
		scope(exit) releaseReader();

		if (m_mustRecv)
			onRead();

		while( readEmpty ){
			if (!connected) {
				return 0;
			}
			getDriverCore().yieldForEvent();
		}
		return (m_slice.length > 0) ? m_slice.length : m_readBuffer.length;
	}

	void close()
	{
		//logTrace("Close TCP");
		//logTrace("closing");
		acquireWriter();
		scope(exit) releaseWriter();

		// checkConnected();

		destroy(m_readBuffer);
		m_slice = null;
		m_buffer = null;

		onClose(null, false);
	}

	void notifyClose()
	{
		onClose(null, false);
	}

	bool waitForData(Duration timeout = 0.seconds)
	{
		if (timeout == Duration.zero)
			timeout = Duration.max;
		mixin(Trace);
		//logTrace("WaitForData enter, timeout %s :: Ptr %s",  timeout.toString(), (cast(void*)this).to!string);
		acquireReader();
		auto _driver = getEventDriver();
		auto tm = _driver.createTimer(null);
		scope(exit) {
			_driver.stopTimer(tm);
			_driver.releaseTimer(tm);
			releaseReader();
		}
		_driver.m_timers.getUserData(tm).owner = Task.getThis();

		if (timeout != Duration.max) _driver.rearmTimer(tm, timeout, false);

		//logTrace("waitForData TCP");
		while (readEmpty) {
			if (!connected) return false;
			//logTrace("Still Connected");
			if (m_mustRecv)
				onRead();
			else {
				//logTrace("Yielding for event in waitForData, waiting? %s", m_settings.reader.isWaiting);
				getDriverCore().yieldForEvent();
				//logTrace("Unyielded");
			}
			if (timeout != Duration.max && !_driver.isTimerPending(tm)) {
				//logTrace("WaitForData TCP: timer signal");
				return false;
			}
		}
		if (readEmpty && !connected) return false;
		//logTrace("WaitForData exit: fiber resumed with read buffer");
		return !readEmpty;
	}

	const(ubyte)[] peek()
	{
		//logTrace("Peek TCP");
		acquireReader();
		scope(exit) releaseReader();

		if (!readEmpty)
			return (m_slice.length > 0) ? cast(const(ubyte)[]) m_slice : m_readBuffer.peek();
		else
			return null;
	}

	void read(ubyte[] dst)
	{
		if (!dst) return;
		mixin(Trace);
		m_bytesRecv += dst.length;
		//logTrace("Read TCP");
		if (m_slice)
		{
			ubyte[] ret = readBuf(dst);
			if (ret.length == dst.length) return;
			else dst = dst[0 .. ret.length];
		}
		acquireReader();
		scope(exit) releaseReader();

		while( dst.length > 0 ){
			while( m_readBuffer.empty ){
				checkConnected();
				if (m_mustRecv)
					onRead();
				else {
					getDriverCore().yieldForEvent(); //wait for data...
				}
			}
			size_t amt = min(dst.length, m_readBuffer.length);

			m_readBuffer.read(dst[0 .. amt]);
			dst = dst[amt .. $];
		}
	}

	void write(in ubyte[] bytes_)
	{
		assert(bytes_ !is null);
		mixin(Trace);
		//logTrace("%s", "write enter");
		acquireWriter();
		scope(exit) releaseWriter();
		checkConnected();
		const(ubyte)[] bytes = bytes_;
		//logTrace("TCP write with %s bytes called", bytes.length);

		bool first = true;
		size_t offset;
		size_t len = bytes.length;
		m_bytesSend += len;
		int retry_limit;
		do {
			if (!first) {
				getDriverCore().yieldForEvent();
			}
			checkConnected();
			offset += conn.send(bytes[offset .. $]);
			if (conn.status.code == Status.RETRY && ++retry_limit < 100)
				continue;
			else if (conn.hasError) {
				throw new ConnectionClosedException(conn.error);
			}
			first = false;
		} while (offset != len);
	}

	void flush()
	{
		//logTrace("%s", "Flush");
		acquireWriter();
		scope(exit) releaseWriter();

		checkConnected();

	}

	void finalize()
	{
		flush();

	}

	void write(InputStream stream, ulong nbytes = 0)
	{
		writeDefault(stream, nbytes);
	}

	void acquireReader() {
		if (Task.getThis() == Task()) {
			//logTrace("Reading without task");
			return;
		}
		//logTrace("%s", "Acquire Reader");
		assert(!amReadOwner());
		m_settings.reader.task = Task.getThis();
		//logTrace("Task waiting in: " ~ (cast(void*)cast(LibasyncTCPConnection)this).to!string);
		m_settings.reader.isWaiting = true;
	}

	void releaseReader() {
		if (Task.getThis() == Task()) return;
		//logTrace("%s", "Release Reader");
		assert(amReadOwner());
		m_settings.reader.isWaiting = false;
	}

	bool amReadOwner() const {
		if (m_settings.reader.isWaiting && m_settings.reader.task == Task.getThis())
			return true;
		return false;
	}

	void acquireWriter() {
		if (Task.getThis() == Task()) return;
		//logTrace("%s", "Acquire Writer");
		assert(!amWriteOwner(), "Failed to acquire writer in task, it was busy");
		m_settings.writer.task = Task.getThis();
		m_settings.writer.isWaiting = true;
	}

	void releaseWriter() {
		if (Task.getThis() == Task()) return;
		//logTrace("%s", "Release Writer");
		assert(amWriteOwner());
		m_settings.writer.isWaiting = false;
	}

	bool amWriteOwner() const {
		if (m_settings.writer.isWaiting && m_settings.writer.task == Task.getThis())
			return true;
		return false;
	}

	private void checkConnected()
	{
		enforce!ConnectionClosedException(connected, "The remote peer has closed the connection.");
		//logTrace("Check Connected");
	}

	private bool tryReadBuf() {
		//logTrace("TryReadBuf with m_buffer: %s", m_buffer.length);
		if (m_buffer) {
			ubyte[] buf = m_buffer[m_slice.length .. $];
			uint ret;
			int retry_limit;
			RETRY: ret = conn.recv(buf);
			if (conn.status.code == Status.RETRY && ++retry_limit < 100) goto RETRY;
			//logTrace("Received: %s", buf[0 .. ret]);
			// check for overflow
			if (ret == buf.length) {
				//logTrace("Overflow detected, revert to ring buffer");
				m_slice = null;
				m_readBuffer.capacity = 64*1024;
				m_readBuffer.put(buf);
				m_buffer = null;
				return false; // cancel slices and revert to the fixed ring buffer
			}

			if (m_slice.length > 0) {
				//logDebug("post-assign m_slice ");
				m_slice = m_slice.ptr[0 .. m_slice.length + ret];
			}
			else {
				//logDebug("using m_buffer");
				m_slice = m_buffer[0 .. ret];
			}
			return true;
		}
		//logTrace("TryReadBuf exit with %d bytes in m_slice, %d bytes in m_readBuffer ", m_slice.length, m_readBuffer.length);

		return false;
	}

	private void onRead() {
		m_mustRecv = true; // assume we didn't receive everything

		if (tryReadBuf()) {
			m_mustRecv = false;
			return;
		}

		assert(!m_slice);

		//logTrace("OnRead with %s", m_readBuffer.freeSpace);


		int retry_limit;
		while( m_readBuffer.freeSpace > 0 ) {
			ubyte[] dst = m_readBuffer.peekDst();
			assert(dst.length <= int.max);
			//logTrace("Try to read up to bytes: %s", dst.length);
			bool read_more;
			do {
				uint ret = conn.recv(dst);
				if( ret > 0 ){
					//logTrace("received bytes: %s", ret);
					m_readBuffer.putN(ret);
				}
				read_more = ret == dst.length;
				// ret == 0! let's look for some errors
				if (read_more) {
					if (m_readBuffer.freeSpace == 0) m_readBuffer.capacity = m_readBuffer.capacity*2;
					dst = m_readBuffer.peekDst();
				}
			} while( read_more );
			if (conn.status.code == Status.ASYNC) {
				m_mustRecv = false; // we'll have to wait
				break; // the kernel's buffer is empty
			}
			else if (conn.status.code == Status.RETRY && ++retry_limit < 100) {
				continue;
			}
			else if (conn.status.code == Status.ABORT) {
				throw new ConnectionClosedException("The connection was closed abruptly while data was expected");
			}
			else if (conn.status.code != Status.OK) {
				// We have a read error and the socket may now even be closed...
				auto err = conn.error;

				//logTrace("receive error %s %s", err, conn.status.code);
				throw new Exception(format("Socket error: %d", conn.status.code));
			}
			else {
				m_mustRecv = false;
				break;
			}
		}
		//logTrace("OnRead exit with free bytes: %s", m_readBuffer.freeSpace);
	}

	/* The AsyncTCPConnection object will be automatically disposed when this returns.
	 * We're given some time to cleanup.
	*/
	private void onClose(in string msg = null, bool wake_ex = true) {
		//logTrace("Got close event: %s", msg);
		if (msg)
			m_error = msg;
		if (!m_closed) {
			s_totalConnections--;

			m_closed = true;

			if (m_tcpImpl.conn && m_tcpImpl.conn.isConnected) {
				m_tcpImpl.conn.kill(Task.getThis() != Task.init); // close the connection
				m_tcpImpl.conn = null;
			}
		}

		Exception ex;
		if (!msg && wake_ex)
			ex = new ConnectionClosedException("Connection closed");
		else if (wake_ex) {
			if (msg == "Software caused connection abort.")
				ex = new ConnectionClosedException(msg);
			else ex = new Exception(msg);
		}

		Task reader = m_settings.reader.task;
		Task writer = m_settings.writer.task;

		bool hasUniqueReader = m_settings.reader.isWaiting;
		bool hasUniqueWriter = m_settings.writer.isWaiting && reader != writer;

		if (hasUniqueReader && Task.getThis() != reader && wake_ex) {
			getDriverCore().resumeTask(reader, null);
		}
		if (hasUniqueWriter && Task.getThis() != writer && wake_ex) {
			getDriverCore().resumeTask(writer, ex);
		}
	}

	void onConnect() {
		bool failure;
		if (m_tcpImpl.conn && m_tcpImpl.conn.isConnected)
		{
			bool inbound = m_tcpImpl.conn.inbound;

			try m_settings.onConnect(this);
			catch ( ConnectionClosedException e) {
				failure = true;
			}
			catch ( Exception e) {
				logError("%s", e.toString);
				failure = true;
			}
			catch ( Throwable e) {
				logError("Fatal error: %s", e.toString);
				failure = true;
			}
			if (inbound) close();
			else if (failure) onClose();
		}
		//logTrace("Finished callback");
	}

	void handler(TCPEvent ev) {
		Exception ex;
		final switch (ev) {
			case TCPEvent.CONNECT:
				m_closed = false;
				// read & write are guaranteed to be successful on any platform at this point
				assert(m_settings.onConnect !is null);
				if (m_tcpImpl.conn.inbound)
					runTask(&onConnect);
				else onConnect();
				m_settings.onConnect = null;
				break;
			case TCPEvent.READ:
				// fill the read buffer and resume any task if waiting
				try onRead();
				catch (Exception e) ex = e;
				if (m_settings.reader.isWaiting)
					getDriverCore().resumeTask(m_settings.reader.task, ex);
				goto case TCPEvent.WRITE;
			case TCPEvent.WRITE:
				// The kernel is ready to have some more data written, all we need to do is wake up the writer
				if (m_settings.writer.isWaiting)
					getDriverCore().resumeTask(m_settings.writer.task, ex);
				break;
			case TCPEvent.CLOSE:
				m_closed = false;
				onClose();
				if (m_settings.onConnect)
					m_settings.onConnect(this);
				m_settings.onConnect = null;
				break;
			case TCPEvent.ERROR:
				m_closed = false;
				onClose(conn.error);
				if (m_settings.onConnect)
					m_settings.onConnect(this);
				m_settings.onConnect = null;
				break;
		}
		return;
	}

	struct Waiter {
		Task task; // we can only have one task waiting for read/write operations
		bool isWaiting; // if a task is actively waiting
	}

	struct Settings {
		void delegate(TCPConnection) onConnect;
		Duration readTimeout;
		bool keepAlive;
		bool tcpNoDelay;
		Waiter reader;
		Waiter writer;
	}

	struct TCPConnectionImpl {
		NetworkAddress localAddr;
		AsyncTCPConnection conn;
	}
}

version(linux) final class LibasyncUDSConnection : UDSConnection {

	private {
		CircularBuffer!ubyte m_readBuffer;
		UDSConnectionImpl m_udsImpl;
		Settings m_settings;
		string m_error;
		bool m_closed = true;
		bool m_mustRecv = true;
		// The socket descriptor is unavailable to motivate low-level/API feature additions
		// rather than high-lvl platform-dependent hacking
		// fd_t socket;
	}

	this(AsyncUDSConnection conn, void delegate(UDSConnection) cb)
	in { assert(conn !is null); }
	do {
		m_settings.onConnect = cb;
		m_readBuffer.capacity = 32*1024;
	}

	~this() {
		if (!m_closed) {
			try onClose(null, false);
			catch (Exception e)
			{
				logError("Failure in UDSConnection dtor: %s", e.msg);
			}
		}
	}

	private @property AsyncUDSConnection conn() {

		return m_udsImpl.conn;
	}

	@property bool connected() const { return !m_closed && m_udsImpl.conn && m_udsImpl.conn.isConnected; }

	@property bool dataAvailableForRead(){
		//logTrace("dataAvailableForRead UDS");
		acquireReader();
		scope(exit) releaseReader();
		return !readEmpty;
	}

	private @property bool readEmpty() {
		return m_readBuffer.empty;
	}

	@property string path() const { enforce!ConnectionClosedException(m_udsImpl.conn, "No Peer Address"); return m_udsImpl.conn.peer.toString(); }

	@property bool empty() { return leastSize == 0; }


	@property ulong leastSize()
	{
		mixin(Trace);
		//logTrace("leastSize UDS");
		acquireReader();
		scope(exit) releaseReader();

		while( readEmpty ){
			if (!connected) {
				return 0;
			}
			getDriverCore().yieldForEvent();
		}
		return m_readBuffer.length;
	}

	void close()
	{
		//logTrace("Close UDS");
		//logTrace("closing");
		acquireWriter();
		scope(exit) releaseWriter();

		destroy(m_readBuffer);
		onClose(null, false);
	}

	void notifyClose()
	{
		onClose(null, false);
	}

	bool waitForData(Duration timeout = 0.seconds)
	{
		if (timeout == Duration.zero)
			timeout = Duration.max;
		mixin(Trace);
		//logTrace("WaitForData enter, timeout %s :: Ptr %s",  timeout.toString(), (cast(void*)this).to!string);
		acquireReader();
		auto _driver = getEventDriver();
		auto tm = _driver.createTimer(null);
		scope(exit) {
			_driver.stopTimer(tm);
			_driver.releaseTimer(tm);
			releaseReader();
		}
		_driver.m_timers.getUserData(tm).owner = Task.getThis();

		if (timeout != Duration.max) _driver.rearmTimer(tm, timeout, false);

		//logTrace("waitForData UDS");
		while (readEmpty) {
			if (!connected) return false;
			//logTrace("Still Connected");
			if (m_mustRecv)
				onRead();
			else {
				//logTrace("Yielding for event in waitForData, waiting? %s", m_settings.reader.isWaiting);
				getDriverCore().yieldForEvent();
				//logTrace("Unyielded");
			}
			if (timeout != Duration.max && !_driver.isTimerPending(tm)) {
				//logTrace("WaitForData UDS: timer signal");
				return false;
			}
		}
		if (readEmpty && !connected) return false;
		//logTrace("WaitForData exit: fiber resumed with read buffer");
		return !readEmpty;
	}

	const(ubyte)[] peek()
	{
		//logTrace("Peek UDS");
		acquireReader();
		scope(exit) releaseReader();

		if (!readEmpty)
			return m_readBuffer.peek();
		else
			return null;
	}

	void read(ubyte[] dst)
	{
		if (!dst) return;
		mixin(Trace);
		//logTrace("Read UDS");
		acquireReader();
		scope(exit) releaseReader();

		while( dst.length > 0 ){
			while( m_readBuffer.empty ){
				checkConnected();
				if (m_mustRecv)
					onRead();
				else {
					getDriverCore().yieldForEvent(); //wait for data...
				}
			}
			size_t amt = min(dst.length, m_readBuffer.length);

			m_readBuffer.read(dst[0 .. amt]);
			dst = dst[amt .. $];
		}
	}

	void write(in ubyte[] bytes_)
	{
		assert(bytes_ !is null);
		mixin(Trace);
		//logTrace("%s", "write enter");
		acquireWriter();
		scope(exit) releaseWriter();
		checkConnected();
		const(ubyte)[] bytes = bytes_;
		//logTrace("UDS write with %s bytes called", bytes.length);

		bool first = true;
		size_t offset;
		size_t len = bytes.length;
		int retry_limit;
		do {
			if (!first) {
				getDriverCore().yieldForEvent();
			}
			checkConnected();
			offset += conn.send(bytes[offset .. $]);

			if (conn.status.code == Status.RETRY && ++retry_limit < 100)
				continue;
			else if (conn.hasError) {
				throw new ConnectionClosedException(conn.error);
			}
			first = false;
		} while (offset != len);
	}

	void flush()
	{
		//logTrace("%s", "Flush");
		acquireWriter();
		scope(exit) releaseWriter();

		checkConnected();
	}

	void finalize()
	{
		flush();

	}

	void write(InputStream stream, ulong nbytes = 0)
	{
		writeDefault(stream, nbytes);
	}
private:
	void acquireReader() {
		if (Task.getThis() == Task()) {
			//logTrace("Reading without task");
			return;
		}
		//logTrace("%s", "Acquire Reader");
		assert(!amReadOwner());
		m_settings.reader.task = Task.getThis();
		//logTrace("Task waiting in: " ~ (cast(void*)cast(LibasyncUDSConnection)this).to!string);
		m_settings.reader.isWaiting = true;
	}

	void releaseReader() {
		if (Task.getThis() == Task()) return;
		//logTrace("%s", "Release Reader");
		assert(amReadOwner());
		m_settings.reader.isWaiting = false;
	}

	bool amReadOwner() const {
		if (m_settings.reader.isWaiting && m_settings.reader.task == Task.getThis())
			return true;
		return false;
	}

	void acquireWriter() {
		if (Task.getThis() == Task()) return;
		//logTrace("%s", "Acquire Writer");
		assert(!amWriteOwner(), "Failed to acquire writer in task, it was busy");
		m_settings.writer.task = Task.getThis();
		m_settings.writer.isWaiting = true;
	}

	void releaseWriter() {
		if (Task.getThis() == Task()) return;
		//logTrace("%s", "Release Writer");
		assert(amWriteOwner());
		m_settings.writer.isWaiting = false;
	}

	bool amWriteOwner() const {
		if (m_settings.writer.isWaiting && m_settings.writer.task == Task.getThis())
			return true;
		return false;
	}

	void checkConnected()
	{
		enforce!ConnectionClosedException(connected, "The remote peer has closed the connection.");
		//logTrace("Check Connected");
	}

	void onRead() {
		m_mustRecv = true; // assume we didn't receive everything

		//logTrace("OnRead with %s", m_readBuffer.freeSpace);
		int retry_limit;
		while( m_readBuffer.freeSpace > 0 ) {
			ubyte[] dst = m_readBuffer.peekDst();
			assert(dst.length <= int.max);
			//logTrace("Try to read up to bytes: %s", dst.length);
			bool read_more;
			do {
				uint ret = conn.recv(dst);
				if( ret > 0 ){
					//logTrace("received bytes: %s", ret);
					m_readBuffer.putN(ret);
				}
				read_more = ret == dst.length;
				// ret == 0! let's look for some errors
				if (read_more) {
					if (m_readBuffer.freeSpace == 0) m_readBuffer.capacity = m_readBuffer.capacity*2;
					dst = m_readBuffer.peekDst();
				}
			} while( read_more );
			if (conn.status.code == Status.ASYNC) {
				m_mustRecv = false; // we'll have to wait
				break; // the kernel's buffer is empty
			} else if (conn.status.code == Status.RETRY && ++retry_limit < 100)
				continue;
			else if (conn.status.code == Status.ABORT) {
				throw new ConnectionClosedException("The connection was closed abruptly while data was expected");
			}
			else if (conn.status.code != Status.OK) {
				// We have a read error and the socket may now even be closed...
				auto err = conn.error;

				//logTrace("receive error %s %s", err, conn.status.code);
				throw new Exception("Socket error: " ~ conn.status.code.to!string);
			}
			else {
				m_mustRecv = false;
				break;
			}
		}
		//logTrace("OnRead exit with free bytes: %s", m_readBuffer.freeSpace);
	}

	/* The AsyncUDSConnection object will be automatically disposed when this returns.
	 * We're given some time to cleanup.
	*/
	void onClose(in string msg = null, bool wake_ex = true) {
		if (msg)
			m_error = msg;
		if (!m_closed) {
			m_closed = true;

			if (m_udsImpl.conn && m_udsImpl.conn.isConnected) {
				m_udsImpl.conn.kill(Task.getThis() != Task.init); // close the connection
				m_udsImpl.conn = null;
			}
		}

		Exception ex;
		if (!msg && wake_ex)
			ex = new ConnectionClosedException("Connection closed");
		else if (wake_ex) {
			if (msg == "Software caused connection abort.")
				ex = new ConnectionClosedException(msg);
			else ex = new Exception(msg);
		}

		Task reader = m_settings.reader.task;
		Task writer = m_settings.writer.task;

		bool hasUniqueReader = m_settings.reader.isWaiting;
		bool hasUniqueWriter = m_settings.writer.isWaiting && reader != writer;

		if (hasUniqueReader && Task.getThis() != reader && wake_ex) {
			getDriverCore().resumeTask(reader, null);
		}
		if (hasUniqueWriter && Task.getThis() != writer && wake_ex) {
			getDriverCore().resumeTask(writer, ex);
		}
	}

	void onConnect() {
		bool failure;
		if (m_udsImpl.conn && m_udsImpl.conn.isConnected)
		{
			bool inbound = m_udsImpl.conn.inbound;

			try m_settings.onConnect(this);
			catch ( ConnectionClosedException e) {
				failure = true;
			}
			catch ( Exception e) {
				logError("%s", e.toString);
				failure = true;
			}
			catch ( Throwable e) {
				logError("Fatal error: %s", e.toString);
				failure = true;
			}
			if (inbound) close();
			else if (failure) onClose();
		}
		//logTrace("Finished callback");
	}

	void handler(EventCode ev) {
		Exception ex;
		final switch (ev) {
			case EventCode.CONNECT:
				m_closed = false;
				// read & write are guaranteed to be successful on any platform at this point
				assert(m_settings.onConnect !is null);
				if (m_udsImpl.conn.inbound)
					runTask(&onConnect);
				else onConnect();
				m_settings.onConnect = null;
				break;
			case EventCode.READ:
				// fill the read buffer and resume any task if waiting
				try onRead();
				catch (Exception e) ex = e;
				if (m_settings.reader.isWaiting)
					getDriverCore().resumeTask(m_settings.reader.task, ex);
				goto case EventCode.WRITE;
			case EventCode.WRITE:
				// The kernel is ready to have some more data written, all we need to do is wake up the writer
				if (m_settings.writer.isWaiting)
					getDriverCore().resumeTask(m_settings.writer.task, ex);
				break;
			case EventCode.CLOSE:
				m_closed = false;
				onClose();
				if (m_settings.onConnect)
					m_settings.onConnect(this);
				m_settings.onConnect = null;
				break;
			case EventCode.ERROR:
				m_closed = false;
				onClose(conn.error);
				if (m_settings.onConnect)
					m_settings.onConnect(this);
				m_settings.onConnect = null;
				break;
		}
		return;
	}

	struct Waiter {
		Task task; // we can only have one task waiting for read/write operations
		bool isWaiting; // if a task is actively waiting
	}

	struct Settings {
		void delegate(UDSConnection) onConnect;
		Duration readTimeout;
		Waiter reader;
		Waiter writer;
	}

	struct UDSConnectionImpl {
		NetworkAddress localAddr;
		AsyncUDSConnection conn;
	}
}


final class LibasyncUDPConnection : UDPConnection {
	private {
		Task m_task;
		AsyncUDPSocket m_udpImpl;
		bool m_canBroadcast;
		NetworkAddress m_peer;

	}

	private @property AsyncUDPSocket socket() {
		return m_udpImpl;
	}

	this(AsyncUDPSocket conn)
	in { assert(conn !is null); }
	do {
		m_udpImpl = conn;
	}

	~this() {
		if (socket && socket.socket > 0) try close(); catch (Throwable) {}
	}

	@property string bindAddress() const {

		return m_udpImpl.local.toAddressString();
	}

	@property NetworkAddress localAddress() const { return m_udpImpl.local; }

	@property bool canBroadcast() const { return m_canBroadcast; }
	@property void canBroadcast(bool val)
	{
		socket.broadcast(val);
		m_canBroadcast = val;
	}

	void close()
	{
		socket.kill();
		m_udpImpl = null;
	}

	bool amOwner() {
		return m_task != Task() && m_task == Task.getThis();
	}

	void acquire()
	{
		assert(m_task == Task(), "Trying to acquire a UDP socket that is currently owned.");
		m_task = Task.getThis();
	}

	void release()
	{
		assert(Task.getThis() == Task() || m_task != Task(), "Trying to release a UDP socket that is not owned.");
		assert(m_task == Task.getThis(), "Trying to release a foreign UDP socket.");
		m_task = Task();
	}

	void connect(string host, ushort port)
	{
		// assert(m_peer == NetworkAddress.init, "Cannot connect to another peer");
		NetworkAddress addr = getEventDriver().resolveHost(host, localAddress.family, true);
		addr.port = port;
		connect(addr);
	}

	void connect(NetworkAddress addr)
	{
		m_peer = addr;
	}

	void send(in ubyte[] data, in NetworkAddress* peer_address = null)
	{
		assert(data.length <= int.max);

		acquire();
		scope(exit)
			release();
		uint ret;
		size_t retries = 3;
		foreach  (i; 0 .. retries) {
			if( peer_address ){
				ret = socket.sendTo(data, *peer_address);
			} else {
				ret = socket.sendTo(data, m_peer);
			}
			if (socket.status.code == Status.ASYNC) {
				getDriverCore().yieldForEvent();
			} else if (socket.status.code == Status.RETRY) {
				continue;
			}

			else break;
		}

		//logTrace("send ret: %s, %s", ret, socket.status.text);
		enforce(socket.status.code == Status.OK, "Error sending UDP packet: " ~ socket.status.text);

		enforce(ret == data.length, "Unable to send full packet.");
	}

	ubyte[] recv(ubyte[] buf = null, NetworkAddress* peer_address = null)
	{
		return recv(Duration.max, buf, peer_address);
	}

	ubyte[] recv(Duration timeout, ubyte[] buf = null, NetworkAddress* peer_address = null)
	{
		size_t tm = size_t.max;
		auto m_driver = getEventDriver();
		if (timeout != Duration.max && timeout > 0.seconds) {
			tm = m_driver.createTimer(null);
			m_driver.rearmTimer(tm, timeout, false);
		}

		acquire();
		scope(exit) {
			release();
			if (tm != size_t.max) {
				m_driver.stopTimer(tm);
				m_driver.releaseTimer(tm);
			}
		}

		assert(buf.length <= int.max);
		if( buf.length == 0 ) buf.length = 65507;
		NetworkAddress from;
		from.family = localAddress.family;
		int retry_limit;
		while(true){
			auto ret = socket.recvFrom(buf, from);
			if( ret > 0 ){
				if( peer_address ) *peer_address = from;
				return buf[0 .. ret];
			}
			else if (socket.status.code == Status.RETRY && ++retry_limit < 100)
				continue;
			else if( socket.status.code != Status.OK ){
				auto err = socket.status.text;
				logDebug("UDP recv err: %s", err);
				enforce(socket.status.code == Status.ASYNC, "Error receiving UDP packet");

				if (timeout != Duration.max) {
					enforce!TimeoutException(timeout > 0.seconds && m_driver.isTimerPending(tm), "UDP receive timeout.");
				}
			}
			getDriverCore().yieldForEvent();
		}
	}

	private void handler(UDPEvent ev)
	{
		//logTrace("UDPConnection event: %s", ev.to!string);
		Exception ex;
		final switch (ev) {
			case UDPEvent.READ:
				if (m_task != Task())
					getDriverCore().resumeTask(m_task, null);

				break;
			case UDPEvent.WRITE:
				if (m_task != Task())
					getDriverCore().resumeTask(m_task, null);

				break;
			case UDPEvent.ERROR:
				getDriverCore.resumeTask(m_task, new Exception(socket.error));
				break;
		}

	}
}



/* The following is used for LibasyncManualEvent */
package void destroyEventWaiters() {
	foreach(arr; s_eventWaiters[])
	{
		arr.clear();
		arr.destroy();
	}
	s_eventWaiters.clear();
	s_eventWaiters.destroy();
}
Vector!(memutils.vector.Array!(Task, ThreadMem), ThreadMem) s_eventWaiters; // Task list in the current thread per instance ID
__gshared Vector!(uint, Malloc) gs_availID;
__gshared uint gs_maxID;
__gshared core.sync.mutex.Mutex gs_mutex;

private uint generateID() {
	uint idx;
	import std.algorithm : max;
	try {
		uint getIdx() {
			if (!gs_availID.empty) {
				immutable uint ret = gs_availID.back;
				gs_availID.removeBack();
				return ret;
			}
			return 0;
		}

		synchronized(gs_mutex) {
			idx = getIdx();
			if (idx == 0) {
				import std.range : iota;
				gs_availID.insert( iota(gs_maxID + 1, max(32, gs_maxID * 2 + 1), 1) );
				gs_maxID = gs_availID[$-1];
				idx = getIdx();
			}
		}
	} catch (Exception e) {
		assert(false, format("Failed to generate necessary ID for Manual Event waiters: %s", e.msg));
	}

	return idx;
}

void recycleID(uint id) {
	try {
		synchronized(gs_mutex) gs_availID ~= id;
	}
	catch (Exception e) {
		assert(false, format("Error destroying Manual Event ID: %d [%s]", id, e.msg));
	}
}
