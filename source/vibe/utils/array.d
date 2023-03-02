/**
	Utility functions for array processing

	Copyright: © 2012 Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibe.utils.array;

import std.algorithm;
import std.range : isInputRange, isOutputRange;
import std.traits;
static import std.utf;


void removeFromArray(T)(ref T[] array, T item)
{
	foreach( i; 0 .. array.length )
		if( array[i] is item ){
			removeFromArrayIdx(array, i);
			return;
		}
}

void removeFromArrayIdx(T)(ref T[] array, size_t idx)
{
	foreach( j; idx+1 .. array.length)
		array[j-1] = array[j];
	array.length = array.length-1;
}

struct FixedAppender(ArrayType : E[], size_t NELEM, E) {
	alias ElemType = Unqual!E;
	private {
		ElemType[NELEM] m_data;
		size_t m_fill;
	}

	void clear()
	{
		m_fill = 0;
	}

	void put(E el)
	{
		m_data[m_fill++] = el;
	}

	static if( is(ElemType == char) ){
		void put(dchar el)
		{
			if( el < 128 ) put(cast(char)el);
			else {
				char[4] buf;
				auto len = std.utf.encode(buf, el);
				put(cast(ArrayType)buf[0 .. len]);
			}
		}
	}

	static if( is(ElemType == wchar) ){
		void put(dchar el)
		{
			if( el < 128 ) put(cast(wchar)el);
			else {
				wchar[3] buf;
				auto len = std.utf.encode(buf, el);
				put(cast(ArrayType)buf[0 .. len]);
			}
		}
	}

	void put(ArrayType arr)
	{
		m_data[m_fill .. m_fill+arr.length] = (cast(ElemType[])arr)[];
		m_fill += arr.length;
	}

	@property ArrayType data() { return cast(ArrayType)m_data[0 .. m_fill]; }

	static if (!is(E == immutable)) {
		void reset() { m_fill = 0; }
	}
}

struct ArraySet(Key)
{
	private {
		Key[4] m_staticEntries;
		Key[] m_entries;
	}

	@property ArraySet dup()
	{
		return ArraySet(m_staticEntries, m_entries.dup);
	}

	bool opBinaryRight(string op)(Key key) if (op == "in") { return contains(key); }

	int opApply(int delegate(ref Key) del)
	{
		foreach (ref k; m_staticEntries)
			if (k != Key.init)
				if (auto ret = del(k))
					return ret;
		foreach (ref k; m_entries)
			if (k != Key.init)
				if (auto ret = del(k))
					return ret;
		return 0;
	}

	bool contains(Key key)
	const {
		foreach (ref k; m_staticEntries) if (k == key) return true;
		foreach (ref k; m_entries) if (k == key) return true;
		return false;
	}

	void insert(Key key)
	{
		if (contains(key)) return;
		foreach (ref k; m_staticEntries)
			if (k == Key.init) {
				k = key;
				return;
			}
		foreach (ref k; m_entries)
			if (k == Key.init) {
				k = key;
				return;
			}
		m_entries ~= key;
	}

	void remove(Key key)
	{
		foreach (ref k; m_staticEntries) if (k == key) { k = Key.init; return; }
		foreach (ref k; m_entries) if (k == key) { k = Key.init; return; }
	}
}
