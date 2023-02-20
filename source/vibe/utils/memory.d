/**
	Utility functions for memory management

	Note that this module currently is a big sand box for testing allocation related stuff.
	Nothing here, including the interfaces, is final but rather a lot of experimentation.

	Copyright: © 2012-2013 RejectedSoftware e.K.
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibe.utils.memory;

//import vibe.core.log;

import core.memory;
import std.conv;
import std.exception : enforce;
import std.traits;

import memutils.utils;

template AllocSize(T)
{
	static if (is(T == class)) {
		// workaround for a strange bug where AllocSize!SSLStream == 0: TODO: dustmite!
		enum dummy = T.stringof ~ __traits(classInstanceSize, T).stringof;
		enum AllocSize = __traits(classInstanceSize, T);
	} else {
		enum AllocSize = T.sizeof;
	}
}

struct FreeListRef(T, bool INIT = true)
{
	enum ElemSize = AllocSize!T;

	static if( is(T == class) ){
		alias TR = T;
	} else {
		alias TR = T*;
	}

	private TR m_object;
	private size_t m_magic = 0x1EE75817; // workaround for compiler bug

	static FreeListRef opCall(ARGS...)(ARGS args)
	{
		//logInfo("refalloc %s/%d", T.stringof, ElemSize);
		FreeListRef ret;
		auto mem = ThreadMem.alloc!(void[])(ElemSize + int.sizeof);
		static if( hasIndirections!T ) GC.addRange(mem.ptr, ElemSize);
		static if( INIT ) ret.m_object = cast(TR)emplace!(Unqual!T)(mem, args);
		else ret.m_object = cast(TR)mem.ptr;
		ret.refCount = 1;
		return ret;
	}

	~this()
	{
		//if( m_object ) logInfo("~this!%s(): %d", T.stringof, this.refCount);
		//if( m_object ) logInfo("ref %s destructor %d", T.stringof, refCount);
		//else logInfo("ref %s destructor %d", T.stringof, 0);
		clear();
		m_magic = 0;
		m_object = null;
	}

	this(this)
	{
		checkInvariants();
		if( m_object ){
			//if( m_object ) logInfo("this!%s(this): %d", T.stringof, this.refCount);
			this.refCount++;
		}
	}

	void opAssign(FreeListRef other)
	{
		clear();
		m_object = other.m_object;
		if( m_object ){
			//logInfo("opAssign!%s(): %d", T.stringof, this.refCount);
			refCount++;
		}
	}

	void clear()
	{
		checkInvariants();
		if( m_object ){
			if( --this.refCount == 0 ){
				static if( INIT ){
					//logInfo("ref %s destroy", T.stringof);
					//typeid(T).destroy(cast(void*)m_object);
					auto objc = m_object;
					static if (is(TR == T)) .destroy(objc);
					else .destroy(*objc);
					//logInfo("ref %s destroyed", T.stringof);
				}
				static if( hasIndirections!T ) GC.removeRange(cast(void*)m_object);
				ThreadMem.free((cast(void*)m_object)[0 .. ElemSize+int.sizeof]);
			}
		}

		m_object = null;
		m_magic = 0x1EE75817;
	}

	@property const(TR) get() const { checkInvariants(); return m_object; }
	@property TR get() { checkInvariants(); return m_object; }
	alias get this;

	private @property ref int refCount()
	const {
		auto ptr = cast(ubyte*)cast(void*)m_object;
		ptr += ElemSize;
		return *cast(int*)ptr;
	}

	private void checkInvariants()
	const {
		assert(m_magic == 0x1EE75817);
		assert(!m_object || refCount > 0);
	}
}