/**
	Interruptible Task synchronization facilities

	Copyright: © 2012-2015 Sönke Ludwig
	Authors: Leonid Kramer, Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
*/
module vibe.core.sync;

import std.exception;

import vibe.core.driver;

import core.atomic;
import core.sync.mutex;
import core.sync.condition;
import std.stdio;
import std.traits : ReturnType;
import memutils.utils;

import vibe.core.log;

enum LockMode {
	lock,
	tryLock,
	defer
}

interface Lockable {
	@safe:
	void lock();
	void unlock();
	bool tryLock();
}

/** RAII lock for the Mutex class.
*/
struct ScopedMutexLock
{
	@disable this(this);
	private {
		Mutex m_mutex;
		bool m_locked;
		LockMode m_mode;
	}

	this(core.sync.mutex.Mutex mutex, LockMode mode = LockMode.lock) {
		assert(mutex !is null);
		m_mutex = mutex;

		final switch (mode) {
			case LockMode.lock: lock(); break;
			case LockMode.tryLock: tryLock(); break;
			case LockMode.defer: break;
		}
	}

	~this()
	{
		if( m_locked )
			try m_mutex.unlock(); catch(Throwable) {}
	}

	@property bool locked() const { return m_locked; }

	void unlock()
	{
		enforce(m_locked);
		m_mutex.unlock();
		m_locked = false;
	}

	bool tryLock()
	{
		enforce(!m_locked);
		return m_locked = m_mutex.tryLock();
	}

	void lock()
	{
		enforce(!m_locked);
		m_locked = true;
		m_mutex.lock();
	}
}


/*
	Only for internal use:
	Ensures that a mutex is locked while executing the given procedure.

	This function works for all kinds of mutexes, in particular for
	$(D core.sync.mutex.Mutex), $(D TaskMutex) and $(D InterruptibleTaskMutex).

	Returns:
		Returns the value returned from $(D PROC), if any.
*/
/// private
ReturnType!PROC performLocked(alias PROC, MUTEX)(MUTEX mutex)
{
	mutex.lock();
	scope (exit) mutex.unlock();
	return PROC();
}

///
unittest {
	setLogLevel(LogLevel.trace);
	int protected_var = 0;
	auto mtx = new TaskMutex;
	mtx.performLocked!({
		protected_var++;
	});
}

/// Semaphore implementation for tasks
/// It is not thread-safe, which is on purpose for performance reasons
/// It will lock up to an adjustable maximum count of internal tasks.
/// Usage example is to limit concurrent connections in a connection pool
class LocalTaskSemaphore
{
	// requires a queue
	import std.container.binaryheap;
	import std.container.array;

	private {
		struct Waiter {
			ManualEvent signal;
			ubyte priority;
			uint seq;
		}

		BinaryHeap!(Array!Waiter, asc) m_waiters;
		uint m_maxLocks;
		uint m_locks;
		uint m_seq;
	}

	this(uint max_locks)
	{
		m_maxLocks = max_locks;
	}

	/// Maximum number of concurrent locks
	@property void maxLocks(uint max_locks) { m_maxLocks = max_locks; }
	/// ditto
	@property uint maxLocks() const { return m_maxLocks; }

	/// Number of concurrent locks still available
	@property uint available() const { return m_maxLocks - m_locks; }

	/** Try to acquire a lock.

		If a lock cannot be acquired immediately, returns `false` and leaves the
		semaphore in its previous state.

		Returns:
			`true` is returned $(I iff) the number of available locks is greater
			than one.
	*/
	bool tryLock()
	{
		if (available > 0)
		{
			m_locks++;
			return true;
		}
		return false;
	}

	/** Acquires a lock.

		Once the limit of concurrent locks is reaced, this method will block
		until the number of locks drops below the limit.
	*/
	void lock()
	{
		import std.algorithm : min;

		if (tryLock())
			return;

		Waiter w;
		w.signal = getEventDriver().createManualEvent();
		scope(exit)
			destroy(w.signal);
		w.priority = Task.getThis().priority;
		w.seq = min(0, m_seq - w.priority);
		if (++m_seq == uint.max)
			rewindSeq();

		m_waiters.insert(w);
		w.signal.waitUninterruptible(w.signal.emitCount);
	}

	/** Gives up an existing lock.
	*/
	void unlock()
	{
		if (m_waiters.length > 0) {
			ManualEvent s = m_waiters.front().signal;
			m_waiters.removeFront();
			s.emit(); // resume one
		} else m_locks--;
	}

	// if true, a goes after b. ie. b comes out front()
	/// private
	static bool asc(ref Waiter a, ref Waiter b)
	{
		if (a.seq == b.seq) {
			if (a.priority == b.priority) {
				// resolve using the pointer address
				return (cast(size_t)&a.signal) > (cast(size_t) &b.signal);
			}
			// resolve using priority
			return a.priority < b.priority;
		}
		// resolve using seq number
		return a.seq > b.seq;
	}

	private void rewindSeq()
	{
		Array!Waiter waiters = m_waiters.release();
		ushort min_seq;
		import std.algorithm : min;
		foreach (ref waiter; waiters[])
			min_seq = min(waiter.seq, min_seq);
		foreach (ref waiter; waiters[])
			waiter.seq -= min_seq;
		m_waiters.assume(waiters);
	}
}


/**
	Mutex implementation for fibers.

	This mutex type can be used in exchange for a core.sync.mutex.Mutex, but
	does not block the event loop when contention happens. Note that this
	mutex does not allow recursive locking.

	Notice:
		Because this class is annotated nothrow, it cannot be interrupted
		using $(D vibe.core.task.Task.interrupt()). The corresponding
		$(D InterruptException) will be deferred until the next blocking
		operation yields the event loop.

		Use $(D InterruptibleTaskMutex) as an alternative that can be
		interrupted.

	See_Also: InterruptibleTaskMutex, RecursiveTaskMutex, core.sync.mutex.Mutex
*/
class TaskMutex : core.sync.mutex.Mutex, Lockable {
	private TaskMutexImpl!false m_impl;

	this(Object o) { m_impl.setup(); super(o); }
	this() { m_impl.setup(); }

	override bool tryLock() nothrow { return m_impl.tryLock(); }
	override void lock() nothrow { m_impl.lock(); }
	override void unlock() nothrow { m_impl.unlock(); }
}

unittest {
	auto mutex = new TaskMutex;

	{
		auto lock = ScopedMutexLock(mutex);
		assert(lock.locked);
		assert(mutex.m_impl.m_locked);

		auto lock2 = ScopedMutexLock(mutex, LockMode.tryLock);
		assert(!lock2.locked);
	}

	assert(!mutex.m_impl.m_locked);

	auto lock = ScopedMutexLock(mutex, LockMode.tryLock);
	assert(lock.locked);
	lock.unlock();
	assert(!lock.locked);

	synchronized(mutex){
		assert(mutex.m_impl.m_locked);
	}
	assert(!mutex.m_impl.m_locked);

	mutex.performLocked!({
		assert(mutex.m_impl.m_locked);
	});
	assert(!mutex.m_impl.m_locked);

	static if (__VERSION__ >= 2067) {
		with(mutex.ScopedMutexLock) {
			assert(mutex.m_impl.m_locked);
		}
	}
}

version (VibeLibevDriver) {} else // timers are not implemented for libev, yet
unittest { // test deferred throwing
	import vibe.core.core;

	auto mutex = new TaskMutex;
	auto t1 = runTask({
		scope (failure) assert(false, "No exception expected in first task!");
		mutex.lock();
		scope (exit) mutex.unlock();
		sleep(20.msecs);
	});

	auto t2 = runTask({
		scope (failure) assert(false, "Only InterruptException supposed to be thrown!");
		mutex.lock();
		scope (exit) mutex.unlock();
		try {
			yield();
			assert(false, "Yield is supposed to have thrown an InterruptException.");
		} catch (InterruptException) {
			// as expected!
		}
	});

	runTask({
		// mutex is now locked in first task for 20 ms
		// the second tasks is waiting in lock()
		t2.interrupt();
		t1.join();
		t2.join();
		assert(!mutex.m_impl.m_locked); // ensure that the scope(exit) has been executed
		//logTrace("333 exitEventLoop");
		exitEventLoop();
	});

	runEventLoop();
	//logTrace("Returning from event loop 338");
}

version (VibeLibevDriver) {} else // timers are not implemented for libev, yet
unittest {
	runMutexUnitTests!TaskMutex();
}


/**
	Alternative to $(D TaskMutex) that supports interruption.

	This class supports the use of $(D vibe.core.task.Task.interrupt()) while
	waiting in the $(D lock()) method. However, because the interface is not
	$(D nothrow), it cannot be used as an object monitor.

	See_Also: $(D TaskMutex), $(D InterruptibleRecursiveTaskMutex)
*/
final class InterruptibleTaskMutex : Lockable {
	private TaskMutexImpl!true m_impl;

	this() { m_impl.setup(); }

	bool tryLock() nothrow { return m_impl.tryLock(); }
	void lock() { m_impl.lock(); }
	void unlock() nothrow { m_impl.unlock(); }
}

version (VibeLibevDriver) {} else // timers are not implemented for libev, yet
unittest {
	runMutexUnitTests!InterruptibleTaskMutex();
}



/**
	Recursive mutex implementation for tasks.

	This mutex type can be used in exchange for a core.sync.mutex.Mutex, but
	does not block the event loop when contention happens.

	Notice:
		Because this class is annotated nothrow, it cannot be interrupted
		using $(D vibe.core.task.Task.interrupt()). The corresponding
		$(D InterruptException) will be deferred until the next blocking
		operation yields the event loop.

		Use $(D InterruptibleRecursiveTaskMutex) as an alternative that can be
		interrupted.

	See_Also: TaskMutex, core.sync.mutex.Mutex
*/
class RecursiveTaskMutex : core.sync.mutex.Mutex, Lockable {
	private RecursiveTaskMutexImpl!false m_impl;

	this(Object o) { m_impl.setup(); super(o); }
	this() { m_impl.setup(); }

	override bool tryLock() { return m_impl.tryLock(); }
	override void lock() { m_impl.lock(); }
	override void unlock() { m_impl.unlock(); }
}

version (VibeLibevDriver) {} else // timers are not implemented for libev, yet
unittest {
	runMutexUnitTests!RecursiveTaskMutex();
}


/**
	Alternative to $(D RecursiveTaskMutex) that supports interruption.

	This class supports the use of $(D vibe.core.task.Task.interrupt()) while
	waiting in the $(D lock()) method. However, because the interface is not
	$(D nothrow), it cannot be used as an object monitor.

	See_Also: $(D RecursiveTaskMutex), $(D InterruptibleTaskMutex)
*/
final class InterruptibleRecursiveTaskMutex : Lockable {
	private RecursiveTaskMutexImpl!true m_impl;

	this() { m_impl.setup(); }

	bool tryLock() { return m_impl.tryLock(); }
	void lock() { m_impl.lock(); }
	void unlock() { m_impl.unlock(); }
}

version (VibeLibevDriver) {} else // timers are not implemented for libev, yet
unittest {
	runMutexUnitTests!InterruptibleRecursiveTaskMutex();
}


private void runMutexUnitTests(M)()
{
	import vibe.core.core;

	auto m = new M;
	scope(exit) m.destroy();
	Task t1, t2;
	void runContendedTasks(bool interrupt_t1, bool interrupt_t2) {
		assert(!m.m_impl.m_locked);

		// t1 starts first and acquires the mutex for 20 ms
		// t2 starts second and has to wait in m.lock()
		t1 = runTask({
			try {
				assert(!m.m_impl.m_locked);
				//logTrace("t1.Before lock");
				m.lock();
				assert(m.m_impl.m_locked);
				//logTrace("t1.Interrupt_t1");
				if (interrupt_t1) {
					//logTrace("t1.sleep 500ms");
					assertThrown!InterruptException(sleep(500.msecs));
				}
				else {
					//logTrace("t1.sleep 20ms");
					assertNotThrown(sleep(20.msecs));
				}

				//logTrace("t1.unlock");
				m.unlock();
			} catch (Throwable e) {
				//logTrace("Threw error in t1: %s", e.toString());
			}
		});
		t2 = runTask({
			assert(!m.tryLock());
			if (interrupt_t2) {
				//logTrace("t2.before lock");
				try m.lock();
				catch (InterruptException) return;
				//logTrace("t2.yield lock");
				try yield(); // rethrows any deferred exceptions
				catch (InterruptException) {
					//logTrace("t2.yield interrupted, unlock");
					m.unlock();
					return;
				}
				assert(false, "Supposed to have thrown an InterruptException.");
			} else assertNotThrown(m.lock());
			//logTrace("t2.before sleep 20ms");
			assert(m.m_impl.m_locked);
			sleep(20.msecs);
			//logTrace("t2.after sleep 20ms");
			m.unlock();
			assert(!m.m_impl.m_locked);
		});
	}

	// basic lock test
	m.performLocked!({
		assert(m.m_impl.m_locked);
	});
	assert(!m.m_impl.m_locked);

	// basic contention test
	runContendedTasks(false, false);
	runTask({
		//logTrace("runTask running task");
		assert(t1.running && t2.running);
		assert(m.m_impl.m_locked);
		//logTrace("runTask join t1");
		t1.join();
		assert(!t1.running && t2.running);
		//logTrace("runTask yield");
		yield(); // give t2 a chance to take the lock
		assert(m.m_impl.m_locked);
		//logTrace("runTask join t2");
		t2.join();
		assert(!t2.running);
		assert(!m.m_impl.m_locked);
		//logTrace("runTask exitEventLoop");
		//logTrace("510 exitEventLoop");
		exitEventLoop();
	});
	runEventLoop();
	yield();
	assert(!m.m_impl.m_locked);

	// interruption test #1
	runContendedTasks(true, false);
	runTask({
		assert(t1.running && t2.running);
		assert(m.m_impl.m_locked);
		t1.interrupt();
		t1.join();
		assert(!t1.running && t2.running);
		yield(); // give t2 a chance to take the lock
		assert(m.m_impl.m_locked);
		t2.join();
		assert(!t2.running);
		assert(!m.m_impl.m_locked);
		//logTrace("530 exitEventLoop");
		exitEventLoop();
	});
	runEventLoop();
	assert(!m.m_impl.m_locked);

	// interruption test #2
	runContendedTasks(false, true);
	runTask({
		assert(t1.running && t2.running);
		assert(m.m_impl.m_locked);
		t2.interrupt();
		t2.join();
		assert(!t2.running);
		static if (is(M == InterruptibleTaskMutex) || is (M == InterruptibleRecursiveTaskMutex))
			assert(t1.running && m.m_impl.m_locked);
		t1.join();
		assert(!t1.running);
		assert(!m.m_impl.m_locked);
		//logTrace("550 exitEventLoop");
		exitEventLoop();
	});
	runEventLoop();
	assert(!m.m_impl.m_locked);
}


/**
	Event loop based condition variable or "event" implementation.

	This class can be used in exchange for a $(D core.sync.condition.Condition)
	to avoid blocking the event loop when waiting.

	Notice:
		Because this class is annotated nothrow, it cannot be interrupted
		using $(D vibe.core.task.Task.interrupt()). The corresponding
		$(D InterruptException) will be deferred until the next blocking
		operation yields the event loop.

		Use $(D InterruptibleTaskCondition) as an alternative that can be
		interrupted.

	See_Also: InterruptibleTaskCondition
*/
class TaskCondition : core.sync.condition.Condition {
	private TaskConditionImpl!(false, Mutex) m_impl;

	this(core.sync.mutex.Mutex mtx) { m_impl.setup(mtx); super(mtx); }
	override @property Mutex mutex() { return m_impl.mutex; }
	override void wait() { m_impl.wait(); }
	override bool wait(Duration timeout) { return m_impl.wait(timeout); }
	override void notify() { m_impl.notify(); }
	override void notifyAll() { m_impl.notifyAll(); }
}


/**
	Alternative to $(D TaskCondition) that supports interruption.

	This class supports the use of $(D vibe.core.task.Task.interrupt()) while
	waiting in the $(D lock()) method. However, because the interface is not
	$(D nothrow), it cannot be used as an object monitor.

	See_Also: $(D TaskCondition)
*/
final class InterruptibleTaskCondition {
	private TaskConditionImpl!(true, Lockable) m_impl;

	this(core.sync.mutex.Mutex mtx) { m_impl.setup(mtx); }
	this(Lockable mtx) { m_impl.setup(mtx); }

	@property Lockable mutex() { return m_impl.mutex; }
	void wait() { m_impl.wait(); }
	bool wait(Duration timeout) { return m_impl.wait(timeout); }
	void notify() { m_impl.notify(); }
	void notifyAll() { m_impl.notifyAll(); }
}


/** Creates a new signal that can be shared between fibers.
*/
ManualEvent createManualEvent()
{
	return getEventDriver().createManualEvent();
}

/** A manually triggered cross-task event.

	Note: the ownership can be shared between multiple fibers and threads.
*/
interface ManualEvent {
	/// A counter that is increased with every emit() call
	@property int emitCount() const nothrow;

	/// Emits the signal, waking up all owners of the signal.
	void emit() nothrow;

	/** Acquires ownership and waits until the signal is emitted.

		Throws:
			May throw an $(D InterruptException) if the task gets interrupted
			using $(D Task.interrupt()).
	*/
	void wait();

	/** Acquires ownership and waits until the emit count differs from the given one.

		Throws:
			May throw an $(D InterruptException) if the task gets interrupted
			using $(D Task.interrupt()).
	*/
	int wait(int reference_emit_count);



	/** Acquires ownership and waits until the emit count differs from the given one or until a timeout is reaced.

		Throws:
			May throw an $(D InterruptException) if the task gets interrupted
			using $(D Task.interrupt()).
	*/
	int wait(Duration timeout, int reference_emit_count);

	/** Same as $(D wait), but defers throwing any $(D InterruptException).

		This method is annotated $(D nothrow) at the expense that it cannot be
		interrupted.
	*/
	int waitUninterruptible(int reference_emit_count) nothrow;

	/// ditto
	int waitUninterruptible(Duration timeout, int reference_emit_count) nothrow;

	/// Same as $(D wait), but will lock the ManualEvent to task-local events and forces the use of emitLocal()
	void waitLocal();

	/// Same as $(D waitLocal), but will also resume when the timeout is reached
	void waitLocal(Duration timeout);

	/// Emits the signal and wakes up local waiters.
	void emitLocal();

protected:
	/**
	Resumes a task on the next run of the event loop if it was waiting locally.
	*/
	final void resumeLocal(Task t)
	{
		import vibe.core.core : rawResume;
		rawResume(t);
	}
}


private struct TaskMutexImpl(bool INTERRUPTIBLE) {
	import std.stdio;
	private {
		shared(bool) m_locked = false;
		shared(uint) m_waiters = 0;
		ManualEvent m_signal;
		debug Task m_owner;
	}

	void setup()
	{
		m_signal = createManualEvent();
	}


	@trusted bool tryLock()
	{
		if (cas(&m_locked, false, true)) {
			debug m_owner = Task.getThis();
			version(MutexPrint) try writefln("mutex %s lock %s", cast(void*)&this, atomicLoad(m_waiters)); catch (Throwable) {}
			return true;
		}
		return false;
	}

	@trusted void lock()
	{
		if (tryLock()) return;
		debug assert(m_owner == Task() || m_owner != Task.getThis(), "Recursive mutex lock.");
		atomicOp!"+="(m_waiters, 1);
		version(MutexPrint) try writefln("mutex %s wait %s", cast(void*)&this, atomicLoad(m_waiters)); catch (Throwable) {}
		scope(exit) atomicOp!"-="(m_waiters, 1);
		auto ecnt = m_signal.emitCount();
		while (!tryLock()) {
			static if (INTERRUPTIBLE) ecnt = m_signal.wait(ecnt);
			else ecnt = m_signal.waitUninterruptible(ecnt);
		}
	}

	@trusted void unlock()
	{
		assert(m_locked);
		debug {
			assert(m_owner == Task.getThis());
			m_owner = Task();
		}
		atomicStore!(MemoryOrder.rel)(m_locked, false);
		version(MutexPrint) try writefln("mutex %s unlock %s", cast(void*)&this, atomicLoad(m_waiters)); catch (Throwable) {}
		if (atomicLoad(m_waiters) > 0)
			m_signal.emit();
	}
}

private struct RecursiveTaskMutexImpl(bool INTERRUPTIBLE) {
	import std.stdio;
	import core.internal.gc.proxy;
	private {
		core.sync.mutex.Mutex m_mutex;
		Task m_owner;
		size_t m_recCount = 0;
		shared(uint) m_waiters = 0;
		ManualEvent m_signal;
		@property bool m_locked() const { return m_recCount > 0; }

		~this() {
			if (m_mutex) ThreadMem.free(m_mutex);
		}
	}

	void setup()
	{
		m_signal = createManualEvent();
		m_mutex = ThreadMem.alloc!(core.sync.mutex.Mutex)();
	}

	@trusted bool tryLock()
	{
		auto self = Task.getThis();
		return m_mutex.performLocked!({
			if (!m_owner) {
				//assert(m_recCount == 0);
				m_recCount = 1;
				m_owner = self;
				return true;
			} else if (m_owner == self) {
				m_recCount++;
				return true;
			}
			return false;
		});
	}

	@trusted void lock()
	{
		if (tryLock()) return;
		atomicOp!"+="(m_waiters, 1);
		version(MutexPrint) try writefln("mutex %s wait %s", cast(void*)&this, atomicLoad(m_waiters)); catch (Throwable) {}
		scope(exit) atomicOp!"-="(m_waiters, 1);
		auto ecnt = m_signal.emitCount();
		while (!tryLock()) {
			static if (INTERRUPTIBLE) ecnt = m_signal.wait(ecnt);
			else ecnt = m_signal.waitUninterruptible(ecnt);
		}
	}

	@trusted void unlock()
	{
		auto self = Task.getThis();
		m_mutex.performLocked!({
			assert(m_owner == self);
			//assert(m_recCount > 0);
			m_recCount--;
			if (m_recCount == 0) {
				m_owner = Task.init;
			}
		});
		version(MutexPrint) try writefln("mutex %s unlock %s", cast(void*)&this, atomicLoad(m_waiters)); catch (Throwable) {}
		if (atomicLoad(m_waiters) > 0)
			m_signal.emit();
	}
}

private struct TaskConditionImpl(bool INTERRUPTIBLE, LOCKABLE) {
	private {
		LOCKABLE m_mutex;

		ManualEvent m_signal;

	}

	static if (is(LOCKABLE == Lockable)) {
		final class MutexWrapper : Lockable {
			private core.sync.mutex.Mutex m_mutex;
			this(core.sync.mutex.Mutex mtx) { m_mutex = mtx; }
			@trusted void lock() { m_mutex.lock(); }
			@trusted void unlock() { m_mutex.unlock(); }
			@trusted bool tryLock() { return m_mutex.tryLock(); }
		}

		void setup(core.sync.mutex.Mutex mtx)
		{
			setup(new MutexWrapper(mtx));
		}
	}

	void setup(LOCKABLE mtx)
	{
		m_mutex = mtx;
		m_signal = createManualEvent();
	}

	@property LOCKABLE mutex() { return m_mutex; }

	@trusted void wait()
	{
		if (auto tm = cast(TaskMutex)m_mutex) {
			assert(tm.m_impl.m_locked);
			debug assert(tm.m_impl.m_owner == Task.getThis());
		}

		auto refcount = m_signal.emitCount;
		m_mutex.unlock();
		scope(exit) m_mutex.lock();
		static if (INTERRUPTIBLE) m_signal.wait(refcount);
		else m_signal.waitUninterruptible(refcount);
	}

	@trusted bool wait(Duration timeout)
	{
		assert(!timeout.isNegative());
		if (auto tm = cast(TaskMutex)m_mutex) {
			assert(tm.m_impl.m_locked);
			debug assert(tm.m_impl.m_owner == Task.getThis());
		}

		auto refcount = m_signal.emitCount;
		m_mutex.unlock();
		scope(exit) m_mutex.lock();

		static if (INTERRUPTIBLE) return m_signal.wait(timeout, refcount) != refcount;
		else return m_signal.waitUninterruptible(timeout, refcount) != refcount;
	}

	@trusted void notify()
	{
		m_signal.emit();
	}

	@trusted void notifyAll()
	{
		m_signal.emit();
	}
}

