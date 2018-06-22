/**
	Generic connection pool for reusing persistent connections across fibers.

	Copyright: © 2012 RejectedSoftware e.K.
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibe.core.connectionpool;

import vibe.core.log;
import vibe.core.driver;

import core.thread;
import vibe.core.sync;
import vibe.utils.memory;
import std.exception;
// todo: Fix error in corruption exception

/**
	Generic connection pool class.

	The connection pool is creating connections using the supplied factory function as needed
	whenever lockConnection() is called. Connections are associated to the calling fiber, as long
	as any copy of the returned LockedConnection object still exists. Connections that are not
	associated 
*/
class ConnectionPool(Connection)
{
	private {
		Connection delegate() m_connectionFactory;
		size_t space_1;
		Connection[] m_connections;
		size_t space_2;
		int[const(Connection)] m_lockCount;
		FreeListRef!LocalTaskSemaphore m_sem;
	}

	this(Connection delegate() connection_factory, uint max_concurrent = uint.max)
	{
		m_connectionFactory = connection_factory;
		m_sem = FreeListRef!LocalTaskSemaphore(max_concurrent);
	}

	@property size_t length() { return m_connections.length; }

	@property void maxConcurrency(uint max_concurrent) {
		m_sem.maxLocks = max_concurrent;
	}

	@property uint maxConcurrency() {
		return m_sem.maxLocks;
	}

	LockedConnection!Connection lockConnection()
	{
		m_sem.lock();
		size_t cidx = size_t.max;
		foreach( i, c; m_connections ){
			auto plc = c in m_lockCount;
			if( !plc || *plc == 0 ){
				cidx = i;
				break;
			}
		}

		Connection conn;
		scope(failure) {
			if (auto plc = conn in m_lockCount)
				*plc = 0;
		}
		if( cidx != size_t.max ){
			logTrace("returning %s connection %d of %d", Connection.stringof, cidx, m_connections.length);
			try conn = m_connections[cidx];
			catch (CorruptionException) {
				cidx = size_t.max;
				conn = m_connectionFactory();
			}

			m_lockCount[conn] = 1;

			static if (__traits(compiles, { bool is_connected = conn.connected(); }())) {
				if (!conn.connected) {
					static if (__traits(compiles, { conn.reconnect(); }()))
						conn.reconnect();
					else {
						m_lockCount.remove(conn);
						m_connections[cidx] = conn = m_connectionFactory();
					}
				}
			}
		} else {
			logDebug("creating new %s connection, all %d are in use", Connection.stringof, m_connections.length);
			conn = m_connectionFactory(); // NOTE: may block
			logDebug(" ... %s", cast(void*)conn);
			m_lockCount[conn] = 1;
		}
		if( cidx == size_t.max ){
			m_connections ~= conn;
			logDebug("Now got %d connections", m_connections.length);
		}
		return LockedConnection!Connection(this, conn);
	}
}

struct LockedConnection(Connection) {
	private {
		ConnectionPool!Connection m_pool;
		Task m_task;
		Connection m_conn;
		size_t spacing;
		uint m_magic = 0xB1345AC2;
	}
	
	private this(ConnectionPool!Connection pool, Connection conn)
	{
		assert(conn !is null);
		m_pool = pool;
		m_conn = conn;
		m_task = Task.getThis();
	}

	this(this)
	{
		enforceEx!CorruptionException(m_magic == 0xB1345AC2, "LockedConnection value corrupted.");
		if( m_conn ){
			auto fthis = Task.getThis();
			assert(fthis is m_task);
			m_pool.m_lockCount[m_conn]++;
			logTrace("conn %s copy %d", cast(void*)m_conn, m_pool.m_lockCount[m_conn]);
		}
	}

	~this()
	{
		enforceEx!CorruptionException(m_magic == 0xB1345AC2, "LockedConnection value corrupted.");
		if( m_conn ){
			auto fthis = Task.getThis();
			assert(fthis is m_task, "Locked connection destroyed in foreign task.");
			auto plc = m_conn in m_pool.m_lockCount;
			if(!plc) return;
			assert(*plc >= 1);
			//logTrace("conn %s destroy %d", cast(void*)m_conn, *plc-1);
			if( --*plc == 0 ){
				m_pool.m_sem.unlock();
				//logTrace("conn %s release", cast(void*)m_conn);
			}
			m_conn = null;
		}
	}


	@property int __refCount() const { return m_pool.m_lockCount.get(m_conn, 0); }
	@property inout(Connection) __conn() inout { return m_conn; }

	alias __conn this;
}

/**
	Thrown if the connection was corrupt for some reason
*/
class CorruptionException : Exception
{
	this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null) @safe pure nothrow
	{
		super("The connection was corrupt: " ~ msg, file, line, next);
	}
}