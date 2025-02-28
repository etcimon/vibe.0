/**
PostgreSQL client implementation.

Features:
$(UL
    $(LI Standalone (does not depend on libpq))
    $(LI Binary formatting (avoids parsing overhead))
    $(LI Prepared statements)
    $(LI Parametrized queries (partially working))
    $(LI $(LINK2 http://www.postgresql.org/docs/9.0/static/datatype-enum.html, Enums))
    $(LI $(LINK2 http://www.postgresql.org/docs/9.0/static/arrays.html, Arrays))
    $(LI $(LINK2 http://www.postgresql.org/docs/9.0/static/rowtypes.html, Composite types))
)

TODOs:
$(UL
    $(LI Redesign parametrized queries)
    $(LI BigInt/Numeric types support)
    $(LI Geometric types support)
    $(LI Network types support)
    $(LI Bit string types support)
    $(LI UUID type support)
    $(LI XML types support)
    $(LI Transaction support)
    $(LI Asynchronous notifications)
    $(LI Better memory management)
    $(LI More friendly PGFields)
)

Bugs:
$(UL
    $(LI Support only cleartext and MD5 $(LINK2 http://www.postgresql.org/docs/9.0/static/auth-methods.html, authentication))
    $(LI Unfinished parameter handling)
    $(LI interval is converted to Duration, which does not support months)
)

$(B Data type mapping:)

$(TABLE
    $(TR $(TH PostgreSQL type) $(TH Aliases) $(TH Default D type) $(TH D type mapping possibilities))
    $(TR $(TD smallint) $(TD int2) $(TD short) <td rowspan="19">Any type convertible from default D type</td>)
    $(TR $(TD integer) $(TD int4) $(TD int))
    $(TR $(TD bigint) $(TD int8) $(TD long))
    $(TR $(TD oid) $(TD reg***) $(TD uint))
    $(TR $(TD decimal) $(TD numeric) $(TD not yet supported))
    $(TR $(TD real) $(TD float4) $(TD float))
    $(TR $(TD double precision) $(TD float8) $(TD double))
    $(TR $(TD character varying(n)) $(TD varchar(n)) $(TD string))
    $(TR $(TD character(n)) $(TD char(n)) $(TD string))
    $(TR $(TD text) $(TD) $(TD string))
    $(TR $(TD "char") $(TD) $(TD char))
    $(TR $(TD bytea) $(TD) $(TD ubyte[]))
    $(TR $(TD timestamp without time zone) $(TD timestamp) $(TD DateTime))
    $(TR $(TD timestamp with time zone) $(TD timestamptz) $(TD SysTime))
    $(TR $(TD date) $(TD) $(TD Date))
    $(TR $(TD time without time zone) $(TD time) $(TD TimeOfDay))
    $(TR $(TD time with time zone) $(TD timetz) $(TD SysTime))
    $(TR $(TD interval) $(TD) $(TD Duration (without months and years)))
    $(TR $(TD boolean) $(TD bool) $(TD bool))
    $(TR $(TD enums) $(TD) $(TD string) $(TD enum))
    $(TR $(TD arrays) $(TD) $(TD Variant[]) $(TD dynamic/static array with compatible element type))
    $(TR $(TD composites) $(TD record, row) $(TD Variant[]) $(TD dynamic/static array, struct or Tuple))
)

Examples:
---
	import memutils.unique, std.typecons;
	auto pdb = new PostgresDB([
		"host" : "/tmp/.s.PGSQL.5432",
		"database" : "postgres",
		"user" : "postgres", // use current process user
		"password" : ""
	]);
	auto conn = pdb.lockConnection();

	auto cmd = scoped!PGCommand(conn, "SELECT typname, typlen FROM pg_type");
	auto dbres = cmd.executeQuery().unique();

	foreach (row; *dbres)
	{
		writeln(row["typname"], ", ", row[1]);
	}
---

Copyright: Copyright Piotr Szturmaj 2011-.
License: $(LINK2 http://boost.org/LICENSE_1_0.txt, Boost License 1.0).
Authors: Piotr Szturmaj
*/

/*
Documentation contains portions copied from PostgreSQL manual (mainly field information and
connection parameters description). License:

Portions Copyright (c) 1996-2010, The PostgreSQL Global Development Group
Portions Copyright (c) 1994, The Regents of the University of California

Permission to use, copy, modify, and distribute this software and its documentation for any purpose,
without fee, and without a written agreement is hereby granted, provided that the above copyright
notice and this paragraph and the following two paragraphs appear in all copies.

IN NO EVENT SHALL THE UNIVERSITY OF CALIFORNIA BE LIABLE TO ANY PARTY FOR DIRECT,
INDIRECT, SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES, INCLUDING LOST PROFITS,
ARISING OUT OF THE USE OF THIS SOFTWARE AND ITS DOCUMENTATION, EVEN IF THE UNIVERSITY
OF CALIFORNIA HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

THE UNIVERSITY OF CALIFORNIA SPECIFICALLY DISCLAIMS ANY WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
PURPOSE. THE SOFTWARE PROVIDED HEREUNDER IS ON AN "AS IS" BASIS, AND THE UNIVERSITY OF
CALIFORNIA HAS NO OBLIGATIONS TO PROVIDE MAINTENANCE, SUPPORT, UPDATES, ENHANCEMENTS,
OR MODIFICATIONS.
*/
module vibe.db.pgsql.pgsql;

import vibe.core.net;
import vibe.core.stream;
import vibe.stream.tls;
import std.bitmanip;
import std.exception;
import std.conv;
import std.traits;
import std.typecons;
import std.string;
import std.digest.md;
import std.typetuple;
import core.bitop;
import std.variant;
import std.algorithm;
import std.datetime;
import std.uuid;
import memutils.utils : ThreadMem;
import memutils.vector;
import memutils.scoped: alloc, PoolStack, ManagedPool, ScopedPool;
import std.digest.sha : sha256Of, SHA256;
import std.digest.hmac;
import std.digest;
import std.base64;
import std.random: uniform;

extern(C) bool gc_inFinalizer();

/**
Data row returned from database servers.

DBRow may be instantiated with any number of arguments. It subtypes base type which
depends on that number:

$(TABLE
    $(TR $(TH Number of arguments) $(TH Base type))
    $(TR $(TD 0) $(TD Variant[] $(BR)$(BR)
    It is default dynamic row, which can handle arbitrary number of columns and any of their types.
    ))
    $(TR $(TD 1) $(TD Specs itself, more precisely Specs[0] $(BR)
    ---
    struct S { int i, float f }

    DBRow!int rowInt;
    DBRow!S rowS;
    DBRow!(Tuple!(string, bool)) rowTuple;
    DBRow!(int[10]) rowSA;
    DBRow!(bool[]) rowDA;
    ---
    ))
    $(TR $(TD >= 2) $(TD Tuple!Specs $(BR)
    ---
    DBRow!(int, string) row1; // two arguments
    DBRow!(int, "i") row2; // two arguments
    ---
    ))
)

If there is only one argument, the semantics depend on its type:

$(TABLE
    $(TR $(TH Type) $(TH Semantics))
    $(TR $(TD base type, such as int) $(TD Row contains only one column of that type))
    $(TR $(TD struct) $(TD Row columns are mapped to fields of the struct in the same order))
    $(TR $(TD Tuple) $(TD Row columns are mapped to tuple fields in the same order))
    $(TR $(TD static array) $(TD Row columns are mapped to array items, they share the same type))
    $(TR $(TD dynamic array) $(TD Same as static array, except that column count may change during runtime))
)
Note: String types are treated as base types.

There is an exception for RDBMSes which are capable of returning arrays and/or composite types. If such a
database server returns array or composite in one column it may be mapped to DBRow as if it was many columns.
For example:
---
struct S { string field1; int field2; }
DBRow!S row;
---
In this case row may handle result that either:
$(UL
    $(LI has two columns convertible to respectively, string and int)
    $(LI has one column with composite type compatible with S)
)

_DBRow's instantiated with dynamic array (and thus default Variant[]) provide additional bracket syntax
for accessing fields:
---
auto value = row["columnName"];
---
There are cases when result contains duplicate column names. Normally column name inside brackets refers
to the first column of that name. To access other columns with that name, use additional index parameter:
---
auto value = row["columnName", 1]; // second column named "columnName"

auto value = row["columnName", 0]; // first column named "columnName"
auto value = row["columnName"]; // same as above
---

Examples:

Default untyped (dynamic) _DBRow:
---
DBRow!() row1;
DBRow!(Variant[]) row2;

assert(is(typeof(row1.base == row2.base)));

auto cmd = new PGCommand(conn, "SElECT typname, typlen FROM pg_type");
auto result = cmd.executeQuery;

foreach (i, row; result)
{
    writeln(i, " - ", row["typname"], ", ", row["typlen"]);
}

result.close;
---
_DBRow with only one field:
---
DBRow!int row;
row = 10;
row += 1;
assert(row == 11);

DBRow!Variant untypedRow;
untypedRow = 10;
---
_DBRow with more than one field:
---
struct S { int i; string s; }
alias Tuple!(int, "i", string, "s") TS;

// all three rows are compatible
DBRow!S row1;
DBRow!TS row2;
DBRow!(int, "i", string, "s") row3;

row1.i = row2.i = row3.i = 10;
row1.s = row2.s = row3.s = "abc";

// these two rows are also compatible
DBRow!(int, int) row4;
DBRow!(int[2]) row5;

row4[0] = row5[0] = 10;
row4[1] = row5[1] = 20;
---
Advanced example:
---
enum Axis { x, y, z }
struct SubRow1 { string s; int[] nums; int num; }
alias Tuple!(int, "num", string, "s") SubRow2;
struct Row { SubRow1 left; SubRow2[] right; Axis axis; string text; }

auto cmd = new PGCommand(conn, "SELECT ROW('text', ARRAY[1, 2, 3], 100),
                                ARRAY[ROW(1, 'str'), ROW(2, 'aab')], 'x', 'anotherText'");

auto row = cmd.executeRow!Row;

assert(row.left.s == "text");
assert(row.left.nums == [1, 2, 3]);
assert(row.left.num == 100);
assert(row.right[0].num == 1 && row.right[0].s == "str");
assert(row.right[1].num == 2 && row.right[1].s == "aab");
assert(row.axis == Axis.x);
assert(row.s == "anotherText");
---
*/
struct DBRow(Specs...)
{
	static if (Specs.length == 0)
		alias Variant[] T;
	else static if (Specs.length == 1)
		alias Specs[0] T;
	else
		alias Tuple!Specs T;

	T base;
	alias base this;

	static if (isDynamicArray!T && !isSomeString!T)
	{
		mixin template elmnt(U : U[]){
			alias U ElemType;
		}
		mixin elmnt!T;
		enum hasStaticLength = false;

		void setLength(size_t length)
		{
			base.length = length;
		}

		void setNull(size_t index)
		{
			static if (isNullable!ElemType)
				base[index] = null;
			else
				throw new Exception("Cannot set NULL to field " ~ to!string(index) ~ " of " ~ T.stringof ~ ", it is not nullable");
		}

		ColumnToIndexDelegate columnToIndex;

		ElemType opIndex(string column, size_t index)
		{
			return base[columnToIndex(column, index)];
		}

		ElemType opIndexAssign(ElemType value, string column, size_t index)
		{
			return base[columnToIndex(column, index)] = value;
		}

		ElemType opIndex(string column)
		{
			return base[columnToIndex(column, 0)];
		}

		ElemType opIndexAssign(ElemType value, string column)
		{
			return base[columnToIndex(column, 0)] = value;
		}

		ElemType opIndex(size_t index)
		{
			return base[index];
		}

		ElemType opIndexAssign(ElemType value, size_t index)
		{
			return base[index] = value;
		}
	}
	else static if (isCompositeType!T)
	{
		static if (isStaticArray!T)
		{
			template ArrayTypeTuple(AT : U[N], U, size_t N)
			{
				static if (N > 1)
					alias TypeTuple!(U, ArrayTypeTuple!(U[N - 1])) ArrayTypeTuple;
				else
					alias TypeTuple!U ArrayTypeTuple;
			}

			alias ArrayTypeTuple!T fieldTypes;
		}
		else
			alias FieldTypeTuple!T fieldTypes;

		enum hasStaticLength = true;

		void set(U, size_t index)(U value)
		{
			static if (isStaticArray!T)
				base[index] = value;
			else
				base.tupleof[index] = value;
		}

		void setNull(size_t index)()
		{
			static if (isNullable!(fieldTypes[index]))
			{
				static if (isStaticArray!T)
					base[index] = null;
				else
					base.tupleof[index] = null;
			}
			else
				throw new Exception("Cannot set NULL to field " ~ to!string(index) ~ " of " ~ T.stringof ~ ", it is not nullable");
		}
	}
	else static if (Specs.length == 1)
	{
		alias TypeTuple!T fieldTypes;
		enum hasStaticLength = true;

		void set(T, size_t index)(T value)
		{
			base = value;
		}

		void setNull(size_t index)()
		{
			static if (isNullable!T)
				base = null;
			else
				throw new Exception("Cannot set NULL to " ~ T.stringof ~ ", it is not nullable");
		}
	}

	static if (hasStaticLength)
	{
		/**
        Checks if received field count matches field count of this row type.

        This is used internally by clients and it applies only to DBRow types, which have static number of fields.
        */
		static pure void checkReceivedFieldCount(int fieldCount)
		{
			if (fieldTypes.length != fieldCount)
				throw new Exception("Received field count is not equal to " ~ T.stringof ~ "'s field count");
		}
	}

	string toString()
	{
		return to!string(base);
	}
}

alias size_t delegate(string column, size_t index) ColumnToIndexDelegate;

/**
Check if type is a composite.

Composite is a type with static number of fields. These types are:
$(UL
    $(LI Tuples)
    $(LI structs)
    $(LI static arrays)
)
*/
template isCompositeType(T)
{
	static if (isTuple!T || is(T == struct) || isStaticArray!T)
		enum isCompositeType = true;
	else
		enum isCompositeType = false;
}

template Nullable(T)
	if (!__traits(compiles, { T t = null; }))
{
	/*
    Currently with void*, because otherwise it wont accept nulls.
    VariantN need to be changed to support nulls without using void*, which may
    be a legitimate type to store, as pointed out by Andrei.
    Preferable alias would be then Algebraic!(T, void) or even Algebraic!T, since
    VariantN already may hold "uninitialized state".
    */
	alias Algebraic!(T, void*) Nullable;
}

template isVariantN(T)
{
	//static if (is(T X == VariantN!(N, Types), uint N, Types...)) // doesn't work due to BUG 5784
	static if (T.stringof.length >= 8 && T.stringof[0..8] == "VariantN") // ugly temporary workaround
		enum isVariantN = true;
	else
		enum isVariantN = false;
}

static assert(isVariantN!Variant);
static assert(isVariantN!(Algebraic!(int, string)));
static assert(isVariantN!(Nullable!int));

template isNullable(T)
{
	static if ((isVariantN!T && T.allowed!(void*)) || is(T X == Nullable!U, U))
		enum isNullable = true;
	else
		enum isNullable = false;
}

static assert(isNullable!Variant);
static assert(isNullable!(Nullable!int));

template nullableTarget(T)
	if (isVariantN!T && T.allowed!(void*))
{
	alias T nullableTarget;
}

template nullableTarget(T : Nullable!U, U)
{
	alias U nullableTarget;
}

private:

const PGEpochDate = Date(2000, 1, 1);
const PGEpochDay = PGEpochDate.dayOfGregorianCal;
const PGEpochTime = TimeOfDay(0, 0, 0);
const PGEpochDateTime = DateTime(2000, 1, 1, 0, 0, 0);

class PGStream
{
	private {
		ConnectionStream m_socket;
		Vector!ubyte m_bytes;
		bool m_tls;
	}
	@property bool isSecured() { return m_tls; }
	@property ConnectionStream socket() { return m_socket; }
	this(TCPConnection socket)
	{
		if (socket) socket.tcpNoDelay = true;
		m_socket = socket;
		m_bytes.reserve(512);
	}

	this(TLSStream stream)
	{
		m_socket = stream;
		m_tls = true;
		m_bytes.reserve(512);
	}

	version(linux)
	this(UDSConnection socket)
	{
		m_socket = socket;
		m_bytes.reserve(512);
	}
	void flush() {
		if (m_bytes.length > 0) {
			m_socket.write(m_bytes[]);
			m_socket.flush();
		}
		m_bytes.length = 0;
	}
	/*
	 * I'm not too sure about this function
	 * Should I keep the length?
	 */
	void write(ubyte[] x)
	{
		m_bytes.insert(x);
	}

	void write(ubyte x)
	{
		write(nativeToBigEndian(x)); // ubyte[]
	}

	void write(short x)
	{
		write(nativeToBigEndian(x)); // ubyte[]
	}

	void write(int x)
	{
		write(nativeToBigEndian(x)); // ubyte[]
	}

	void write(long x)
	{
		write(nativeToBigEndian(x));
	}

	void write(float x)
	{
		write(nativeToBigEndian(x)); // ubyte[]
	}

	void write(double x)
	{
		write(nativeToBigEndian(x));
	}

	void writeString(string x)
	{
		write(cast(ubyte[])(x));
	}

	void writeCString(string x)
	{
		writeString(x);
		write('\0');
	}

	void writeCString(char[] x)
	{
		write(cast(ubyte[])x);
		write('\0');
	}

	void write(const ref Date x)
	{
		write(cast(int)(x.dayOfGregorianCal - PGEpochDay));
	}

	void write(const ref TimeOfDay x)
	{
		write(cast(int)((x - PGEpochTime).total!"usecs"));
	}

	void write(const ref DateTime x) // timestamp
	{
		write(cast(int)((x - PGEpochDateTime).total!"usecs"));
	}

	void write(const ref SysTime x) // timestamptz
	{
		write(cast(int)((x - SysTime(PGEpochDateTime, UTC())).total!"usecs"));
	}

	// BUG: Does not support months
	void write(const ref core.time.Duration x) // interval
	{
		int months = cast(int)(x.split!"weeks".weeks/28);
		int days = cast(int)x.split!"days".days;
		long usecs = x.total!"usecs" - convert!("days", "usecs")(days);

		write(usecs);
		write(days);
		write(months);
	}

	void writeTimeTz(const ref SysTime x) // timetz
	{
		TimeOfDay t = cast(TimeOfDay)x;
		write(t);
		write(cast(int)0);
	}
}

char[32] MD5toHex(T...)(in T data)
{
	return md5Of(data).toHexString!(LetterCase.lower);
}

struct Message
{
	PGConnection conn;
	char type;
	ubyte[] data;

	private size_t position = 0;

	T read(T, Params...)(Params p)
	{
		T value;
		read(value, p);
		return value;
	}

	void read()(out char x)
	{
		x = data[position++];
	}


	void read(Int)(out Int x) if((isIntegral!Int || isFloatingPoint!Int) && Int.sizeof > 1)
	{
		ubyte[Int.sizeof] buf;
		buf[] = data[position..position+Int.sizeof];
		x = bigEndianToNative!Int(buf);
		position += Int.sizeof;
	}

	string readCString()
	{
		string x;
		readCString(x);
		return x;
	}

	void readCString(out string x)
	{
		ubyte* p = data.ptr + position;

		while (*p > 0)
			p++;
		x = cast(string)data[position .. cast(size_t)(p - data.ptr)];
		position = cast(size_t)(p - data.ptr + 1);
	}

	string readString(int len)
	{
		string x;
		readString(x, len);
		return x;
	}

	void readString(out string x, int len)
	{
		x = cast(string)(data[position .. position + len]);
		position += len;
	}

	void read()(out bool x)
	{
		x = cast(bool)data[position++];
	}

	void read()(out ubyte[] x, int len)
	{
		enforce(position + len <= data.length);
		x = data[position .. position + len];
		position += len;
	}

	void read()(out UUID u) // uuid
	{
		ubyte[16] uuidData = data[position .. position + 16];
		position += 16;
		u = UUID(uuidData);
	}

	void read()(out Date x) // date
	{
		int days = read!int; // number of days since 1 Jan 2000
		x = PGEpochDate + dur!"days"(days);
	}

	void read()(out TimeOfDay x) // time
	{
		long usecs = read!long;
		x = PGEpochTime + dur!"usecs"(usecs);
	}

	void read()(out DateTime x) // timestamp
	{
		long usecs = read!long;
		x = PGEpochDateTime + dur!"usecs"(usecs);
	}

	void read()(out SysTime x) // timestamptz
	{
		long usecs = read!long;
		x = SysTime(PGEpochDateTime + dur!"usecs"(usecs), UTC());
		x.timezone = LocalTime();
	}

	// BUG: Does not support months
	void read()(out core.time.Duration x) // interval
	{
		long usecs = read!long;
		int days = read!int;
		int months = read!int;

		x = dur!"days"(days) + dur!"usecs"(usecs);
	}

	SysTime readTimeTz() // timetz
	{
		TimeOfDay time = read!TimeOfDay;
		int zone = read!int / 60; // originally in seconds, convert it to minutes
		Duration duration = dur!"minutes"(zone);
		auto stz = new immutable SimpleTimeZone(duration);
		return SysTime(DateTime(Date(0, 1, 1), time), stz);
	}

	T readComposite(T)()
	{
		alias DBRow!T Record;

		static if (Record.hasStaticLength)
		{
			alias Record.fieldTypes fieldTypes;

			static string genFieldAssigns() // CTFE
			{
				string s = "";

				foreach (i; 0 .. fieldTypes.length)
				{
					s ~= "read(fieldOid);\n";
					s ~= "read(fieldLen);\n";
					s ~= "if (fieldLen == -1)\n";
					s ~= text("record.setNull!(", i, ");\n");
					s ~= "else\n";
					s ~= text("record.set!(fieldTypes[", i, "], ", i, ")(",
						"readBaseType!(fieldTypes[", i, "])(fieldOid, fieldLen)",
						");\n");
					// text() doesn't work with -inline option, CTFE bug
				}

				return s;
			}
		}

		Record record;

		int fieldCount, fieldLen;
		uint fieldOid;

		read(fieldCount);

		static if (Record.hasStaticLength)
			mixin(genFieldAssigns);
		else
		{
			record.setLength(fieldCount);

			foreach (i; 0 .. fieldCount)
			{
				read(fieldOid);
				read(fieldLen);

				if (fieldLen == -1)
					record.setNull(i);
				else
					record[i] = readBaseType!(Record.ElemType)(fieldOid, fieldLen);
			}
		}

		return record.base;
	}
	mixin template elmnt(U : U[])
	{
		alias U ElemType;
	}
	private AT readDimension(AT)(int[] lengths, uint elementOid, int dim)
	{

		mixin elmnt!AT;

		int length = lengths[dim];

		AT array;
		static if (isDynamicArray!AT)
			array.length = length;

		int fieldLen;

		foreach(i; 0 .. length)
		{
			static if (isArray!ElemType && !isSomeString!ElemType)
				array[i] = readDimension!ElemType(lengths, elementOid, dim + 1);
			else
			{
				static if (isNullable!ElemType)
					alias nullableTarget!ElemType E;
				else
					alias ElemType E;

				read(fieldLen);
				if (fieldLen == -1)
				{
					static if (isNullable!ElemType || isSomeString!ElemType)
						array[i] = null;
					else
						throw new Exception("Can't set NULL value to non nullable type");
				}
				else
					array[i] = readBaseType!E(elementOid, fieldLen);
			}
		}

		return array;
	}

	T readArray(T)()
		if (isArray!T)
	{
		alias multiArrayElemType!T U;

		// todo: more validation, better lowerBounds support
		int dims, hasNulls;
		uint elementOid;
		int[] lengths, lowerBounds;

		read(dims);
		read(hasNulls); // 0 or 1
		read(elementOid);

		if (dims == 0)
			return T.init;

		enforce(arrayDimensions!T == dims, "Dimensions of arrays do not match");
		static if (!isNullable!U && !isSomeString!U)
			enforce(!hasNulls, "PostgreSQL returned NULLs but array elements are not Nullable");

		lengths.length = lowerBounds.length = dims;

		int elementCount = 1;

		foreach(i; 0 .. dims)
		{
			int len;

			read(len);
			read(lowerBounds[i]);
			lengths[i] = len;

			elementCount *= len;
		}

		T array = readDimension!T(lengths, elementOid, 0);

		return array;
	}

	T readEnum(T)(int len)
	{
		string genCases() // CTFE
		{
			string s;

			foreach (name; __traits(allMembers, T))
			{
				s ~= text(`case "`, name, `": return T.`, name, `;`);
			}

			return s;
		}

		string enumMember = readString(len);

		switch (enumMember)
		{
			mixin(genCases);
			default: throw new ConvException("Can't set enum value '" ~ enumMember ~ "' to enum type " ~ T.stringof);
		}
	}

	T readBaseType(T)(uint oid, int len = 0)
	{
		auto convError(T)()
		{
			string* type = oid in baseTypes;
			return new ConvException("Can't convert PostgreSQL's type " ~ (type ? *type : to!string(oid)) ~ " to " ~ T.stringof);
		}

		switch (oid)
		{
			case 16: // bool
				static if (isConvertible!(T, bool))
					return _to!T(read!bool);
				else
					throw convError!T();
			case 26, 24, 2202, 2203, 2204, 2205, 2206, 3734, 3769: // oid and reg*** aliases
				static if (isConvertible!(T, uint))
					return _to!T(read!uint);
				else
					throw convError!T();
			case 21: // int2
				static if (isConvertible!(T, short))
					return _to!T(read!short);
				else
					throw convError!T();
			case 23: // int4
				static if (isConvertible!(T, int))
					return _to!T(read!int);
				else
					throw convError!T();
			case 20: // int8
				static if (isConvertible!(T, long))
					return _to!T(read!long);
				else
					throw convError!T();
			case 700: // float4
				static if (isConvertible!(T, float))
					return _to!T(read!float);
				else
					throw convError!T();
			case 701: // float8
				static if (isConvertible!(T, double))
					return _to!T(read!double);
				else
					throw convError!T();
			case 1042, 1043, 25, 19, 705: // bpchar, varchar, text, name, unknown
				static if (isConvertible!(T, string))
					return _to!T(readString(len));
				else
					throw convError!T();
			case 17: // bytea
				static if (is(T == ubyte[]))
					return read!(ubyte[])(len);
				else static if (is(T == string))
					return cast(string) read!(ubyte[])(len);
				else static if (isConvertible!(T, ubyte[]))
					return _to!T(read!(ubyte[])(len));
				else
					throw convError!T();
			case 2950: // UUID
				static if(isConvertible!(T, UUID))
					return _to!T(read!UUID());
				else
					throw convError!T();
			case 18: // "char"
				static if (isConvertible!(T, char))
					return _to!T(read!char);
				else
					throw convError!T();
			case 1082: // date
				static if (isConvertible!(T, Date))
					return _to!T(read!Date);
				else
					throw convError!T();
			case 1083: // time
				static if (isConvertible!(T, TimeOfDay))
					return _to!T(read!TimeOfDay);
				else
					throw convError!T();
			case 1114: // timestamp
				static if (isConvertible!(T, DateTime))
					return _to!T(read!DateTime);
				else
					throw convError!T();
			case 1184: // timestamptz
				static if (isConvertible!(T, SysTime))
					return _to!T(read!SysTime);
				else
					throw convError!T();
			case 1186: // interval
				static if (isConvertible!(T, core.time.Duration))
					return _to!T(read!(core.time.Duration));
				else
					throw convError!T();
			case 1266: // timetz
				static if (isConvertible!(T, SysTime))
					return _to!T(readTimeTz);
				else
					throw convError!T();
			case 2249: // record and other composite types
				static if (isVariantN!T && T.allowed!(Variant[]))
					return T(readComposite!(Variant[]));
				else
					return readComposite!T;
			case 2287: // _record and other arrays
				static if (isArray!T && !isSomeString!T)
					return readArray!T;
				else static if (isVariantN!T && T.allowed!(Variant[]))
					return T(readArray!(Variant[]));
				else
					throw convError!T();
			default:
				if (oid in conn.arrayTypes)
					goto case 2287;
				else if (oid in conn.compositeTypes)
					goto case 2249;
				else if (oid in conn.enumTypes)
				{
					static if (is(T == enum))
						return readEnum!T(len);
					else static if (isConvertible!(T, string))
						return _to!T(readString(len));
					else
						throw convError!T();
				}
		}

		throw convError!T();
	}
}

import std.digest : isDigest, digestLength;

ubyte[] Hi(H = SHA256)(in string _password, in ubyte[] _salt, int iterations = 4096, uint dkLen = 256)
	if (isDigest!H)
in
{
	import std.exception;
	enforce(dkLen < (2^32 - 1) * digestLength!H, "Derived key too long");
}
body
{
	ubyte[] password = cast(ubyte[])_password;
	ubyte[] salt = _salt.dup;
	salt ~= cast(ubyte[])[0,0,0,1];

	auto hmac1 = hmacSha256(password, salt).dup;
	auto hmac_ = hmac1.dup;

	for (int i = 0; i < iterations - 1; i++)
	{
		hmac1 = hmacSha256(password, hmac1).dup;
		hmac_ = xorBuffers(hmac_, hmac1);
	}

	return hmac_;
}


ubyte[] xorBuffers(ubyte[] a, ubyte[] b) {
  ubyte[] res;
  if (a.length > b.length) {
    for (size_t i = 0; i < b.length; i++) {
      res ~= (a[i] ^ b[i]);
    }
  } else {
    for (size_t j = 0; j < a.length; j++) {
      res ~= (a[j] ^ b[j]);
    }
  }
  return res;
}

// HMAC-SHA-256 wrapper
ubyte[] hmacSha256(ubyte[] key, ubyte[] data) {
    return hmac!SHA256(cast(ubyte[])data, key).dup;
}

//https://github.com/LightBender/SecureD/blob/master/source/secured/random.d#L23
@trusted public ubyte[] random(uint bytes)
{

    if (bytes == 0) {
        throw new Exception("The number of requested bytes must be greater than zero.");
    }
    ubyte[] buffer = new ubyte[bytes];

	version(Posix)
		{
        import std.exception;
        import std.format;
        import std.stdio;

        try {
            //Initialize the system random file buffer
            File urandom = File("/dev/urandom", "rb");
            urandom.setvbuf(null, _IONBF);
            scope(exit) urandom.close();

            //Read into the buffer
            try {
                buffer = urandom.rawRead(buffer);
            }
            catch(ErrnoException ex) {
                throw new Exception(format("Cannot get the next random bytes. Error ID: %d, Message: %s", ex.errno, ex.msg));
            }
            catch(Exception ex) {
                throw new Exception(format("Cannot get the next random bytes. Message: %s", ex.msg));
            }
        }
        catch(ErrnoException ex) {
            throw new Exception(format("Cannot initialize the system RNG. Error ID: %d, Message: %s", ex.errno, ex.msg));
        }
        catch(Exception ex) {
            throw new Exception(format("Cannot initialize the system RNG. Message: %s", ex.msg));
        }
    }
    else version(Windows)
    {
        import core.sys.windows.windows;
		import core.sys.windows.wincrypt;
        import std.format;

        HCRYPTPROV hCryptProv;

        //Get the cryptographic context from Windows
        if (!CryptAcquireContext(&hCryptProv, NULL, NULL, PROV_RSA_FULL, CRYPT_VERIFYCONTEXT)) {
            throw new Exception("Unable to acquire Cryptographic Context.");
        }
        //Release the context when finished
        scope(exit) CryptReleaseContext(hCryptProv, 0);

        //Generate the random bytes
        if (!CryptGenRandom(hCryptProv, cast(DWORD)buffer.length, buffer.ptr)) {
            throw new Exception(format("Cannot get the next random bytes. Error ID: %d", GetLastError()));
        }
    }
    else
    {
        static assert(0, "SecureD does not support this OS.");
    }
    return buffer;
}
// workaround, because std.conv currently doesn't support VariantN
template _to(T)
{
	static if (isVariantN!T)
	T _to(S)(S value) { T t = value; return t; }
	else
	T _to(A...)(A args) { static if (is(A == T)) return args; else return to!T(args); }
}

template isConvertible(T, S)
{
	static if (__traits(compiles, { S s; _to!T(s); }) || (isVariantN!T && T.allowed!S))
		enum isConvertible = true;
	else
		enum isConvertible = false;
}

template arrayDimensions(T : T[])
{
	static if (isArray!T && !isSomeString!T)
		enum arrayDimensions = arrayDimensions!T + 1;
	else
		enum arrayDimensions = 1;
}

template arrayDimensions(T)
{
	enum arrayDimensions = 0;
}

template multiArrayElemType(T : T[])
{
	static if (isArray!T && !isSomeString!T)
		alias multiArrayElemType!T multiArrayElemType;
	else
		alias T multiArrayElemType;
}

template multiArrayElemType(T)
{
	alias T multiArrayElemType;
}

static assert(arrayDimensions!(int) == 0);
static assert(arrayDimensions!(int[]) == 1);
static assert(arrayDimensions!(int[][]) == 2);
static assert(arrayDimensions!(int[][][]) == 3);

enum TransactionStatus : char { OutsideTransaction = 'I', InsideTransaction = 'T', InsideFailedTransaction = 'E' };

enum string[int] baseTypes = [
	// boolean types
	16 : "bool",
	// bytea types
	17 : "bytea",
	// character types
	18 : `"char"`, // "char" - 1 byte internal type
	1042 : "bpchar", // char(n) - blank padded
	1043 : "varchar",
	25 : "text",
	19 : "name",
	// numeric types
	21 : "int2",
	23 : "int4",
	20 : "int8",
	700 : "float4",
	701 : "float8",
	1700 : "numeric",
	1114: "timestamp"
];

public:

enum PGType : int
{
	OID = 26,
	NAME = 19,
	REGPROC = 24,
	BOOLEAN = 16,
	BYTEA = 17,
	CHAR = 18, // 1 byte "char", used internally in PostgreSQL
	BPCHAR = 1042, // Blank Padded char(n), fixed size
	VARCHAR = 1043,
	TEXT = 25,
	INT2 = 21,
	INT4 = 23,
	INT8 = 20,
	FLOAT4 = 700,
	FLOAT8 = 701,
	NUMERIC = 1700,
	TIMESTAMP = 1114,
	INET = 869,
	JSONB = 3802,
	INTERVAL = 1186

};

class ParamException : Exception
{
	this(string msg)
	{
		super(msg);
	}
}

/// Exception thrown on server error
class ServerErrorException: Exception
{
	/// Contains information about this _error. Aliased to this.
	ResponseMessage error;
	alias error this;

	this(string msg)
	{
		super(msg);
	}

	this(ResponseMessage error)
	{
		super(error.toString());
		this.error = error;
	}
}

/**
Class encapsulating errors and notices.

This class provides access to fields of ErrorResponse and NoticeResponse
sent by the server. More information about these fields can be found
$(LINK2 http://www.postgresql.org/docs/9.0/static/protocol-error-fields.html,here).
*/
class ResponseMessage
{
	private string[char] fields;

	private string getOptional(char type)
	{
		string* p = type in fields;
		return p ? *p : "";
	}

	/// Message fields
	@property string severity()
	{
		return fields['S'];
	}

	/// ditto
	@property string code()
	{
		return fields['C'];
	}

	/// ditto
	@property string message()
	{
		return fields['M'];
	}

	/// ditto
	@property string detail()
	{
		return getOptional('D');
	}

	/// ditto
	@property string hint()
	{
		return getOptional('H');
	}

	/// ditto
	@property string position()
	{
		return getOptional('P');
	}

	/// ditto
	@property string internalPosition()
	{
		return getOptional('p');
	}

	/// ditto
	@property string internalQuery()
	{
		return getOptional('q');
	}

	/// ditto
	@property string where()
	{
		return getOptional('W');
	}

	/// ditto
	@property string file()
	{
		return getOptional('F');
	}

	/// ditto
	@property string line()
	{
		return getOptional('L');
	}

	/// ditto
	@property string routine()
	{
		return getOptional('R');
	}

	/**
    Returns summary of this message using the most common fields (severity,
    code, message, detail, hint)
    */
	override string toString()
	{
		string s = severity ~ ' ' ~ code ~ ": " ~ message;

		string* detail = 'D' in fields;
		if (detail)
			s ~= "\nDETAIL: " ~ *detail;

		string* hint = 'H' in fields;
		if (hint)
			s ~= "\nHINT: " ~ *hint;
		return s;
	}
}

/**
Class representing connection to PostgreSQL server.
*/
class PGConnection
{
private:
	PGStream stream;
	string[string] serverParams;
	int serverProcessID;
	int serverSecretKey;
	TransactionStatus trStatus;
	ulong lastPrepared = 0;
	uint[uint] arrayTypes;
	uint[][uint] compositeTypes;
	string[uint][uint] enumTypes;
	bool activeResultSet;

	string reservePrepared()
	{
		synchronized (this)
		{

			return to!string(lastPrepared++);
		}
	}

	Message getMessage(bool skip = false)
	{
		stream.flush();

		char type;
		int len;
		ubyte[1] ub;

		stream.socket.read(ub); // message type

		type = bigEndianToNative!char(ub);

		ubyte[4] ubi;
		stream.socket.read(ubi); // message length, doesn't include type byte

		len = bigEndianToNative!int(ubi) - 4;
		if (!skip && len > 0) {
			ubyte[] msg = .alloc!(ubyte[])(len);

			stream.socket.read(msg);
			return Message(this, type, msg);
		}
		else if (len > 0) {
			Vector!ubyte msg = Vector!ubyte(len);
			stream.socket.read(msg[]);
			return Message(this, type, null);
		} else {
			return Message(this, type, null);
		}
	}

	void sendStartupMessage(const string[string] params)
	{
		bool localParam(string key)
		{
			switch (key)
			{
				case "host", "port", "password", "ssl": return true;
				default: return false;
			}
		}

		int len = 9; // length (int), version number (int) and parameter-list's delimiter (byte)

		foreach (key, value; params)
		{
			if (localParam(key))
				continue;

			len += key.length + value.length + 2;
		}

		stream.write(len);
		stream.write(0x0003_0000); // version number 3
		foreach (key, value; params)
		{
			if (localParam(key))
				continue;
			stream.writeCString(key);
			stream.writeCString(value);
		}
		stream.write(cast(ubyte)0);
	}

	void sendPasswordMessage(string password)
	{
		int len = cast(int)(4 + password.length + 1);

		stream.write('p');
		stream.write(len);
		stream.writeCString(password);
	}

	void sendParseMessage(string statementName, string query, int[] oids)
	{
		int len = cast(int)(4 + statementName.length + 1 + query.length + 1 + 2 + oids.length * 4);
		bool failed;
		try stream.write('P');
		catch (Exception e) {
			failed = true;
		}
		if (failed) {
			close();
			throw new Exception("Error in parse: " ~ statementName ~ " query: " ~ query);
		}
		stream.write(len);
		stream.writeCString(statementName);
		stream.writeCString(query);
		stream.write(cast(short)oids.length);

		foreach (oid; oids)
			stream.write(oid);
	}

	void sendCloseMessage(DescribeType type, string name)
	{
		stream.write('C');
		stream.write(cast(int)(4 + 1 + name.length + 1));
		stream.write(cast(char)type);
		stream.writeCString(name);
	}

	void sendTerminateMessage()
	{
		stream.write('X');
		stream.write(cast(int)4);
		stream.flush();
	}

	void sendBindMessage(string portalName, string statementName, PGParameters params)
	{
		int paramsLen = 0;
		bool hasText = false;

		foreach (param; params)
		{
			enforce(param.value.hasValue, new ParamException(format("Parameter $%d value is not initialized", param.index)));

			void checkParam(T)(int len)
			{
				if (param.value != null)
				{
					enforce(param.value.convertsTo!T, new ParamException(format("Parameter's value is not convertible to %s")));
					paramsLen += len;
				}
			}

			/*final*/ switch (param.type)
			{
				case PGType.INT2: checkParam!short(2); break;
				case PGType.INT4: checkParam!int(4); break;
				case PGType.INT8: checkParam!long(8); break;
				case PGType.TEXT:
				case PGType.BOOLEAN:
				case PGType.TIMESTAMP:
				case PGType.VARCHAR:
				case PGType.INET:
				case PGType.NUMERIC:
				case PGType.JSONB:
				case PGType.INTERVAL:
					paramsLen += param.value.coerce!string.length;
					hasText = true;
					break;
				default: assert(0, "Not implemented");
			}
		}

		int len = cast(int)( 4 + portalName.length + 1 + statementName.length + 1 + (hasText ? (params.length*2) : 2) + 2 + 2 +
			params.length * 4 + paramsLen + 2 + 2 );

		stream.write('B');
		stream.write(len);
		stream.writeCString(portalName);
		stream.writeCString(statementName);
		if(hasText)
		{
			stream.write(cast(short) params.length);
			foreach(param; params)
				if(param.type == PGType.TEXT || param.type == PGType.INET || param.type == PGType.VARCHAR || param.type == PGType.TIMESTAMP
					|| param.type == PGType.NUMERIC || param.type == PGType.BOOLEAN || param.type == PGType.JSONB || param.type == PGType.INTERVAL)
					stream.write(cast(short) 0); // text format
				else
					stream.write(cast(short) 1); // binary format
		} else {
			stream.write(cast(short)1); // one parameter format code
			stream.write(cast(short)1); // binary format
		}
		stream.write(cast(short)params.length);

		foreach (param; params)
		{
			if (param.value.coerce!string == null)
			{
				stream.write(cast(int)-1);
				continue;
			}

			switch (param.type)
			{
				case PGType.INT2:
					stream.write(cast(int)2);
					stream.write(param.value.get!short);
					break;
				case PGType.INT4:
					stream.write(cast(int)4);
					stream.write(param.value.get!int);
					break;
				case PGType.INT8:
					stream.write(cast(int)8);
					stream.write(param.value.get!long);
					break;
				case PGType.TEXT:
				case PGType.BOOLEAN:
				case PGType.TIMESTAMP:
				case PGType.VARCHAR:
				case PGType.INET:
				case PGType.NUMERIC:
				case PGType.JSONB:
				case PGType.INTERVAL:
					auto s = param.value.coerce!string;
					if (!s) {
						stream.write(cast(int)0);
						continue;
					}
					stream.write(cast(int) s.length);
					stream.write(cast(ubyte[]) s);
					break;
				default:
					assert(0, "Not implemented");
			}
		}

		stream.write(cast(short)1); // one result format code
		stream.write(cast(short)1); // binary format
	}

	enum DescribeType : char { Statement = 'S', Portal = 'P' }

	void sendDescribeMessage(DescribeType type, string name)
	{
		stream.write('D');
		stream.write(cast(int)(4 + 1 + name.length + 1));
		stream.write(cast(char)type);
		stream.writeCString(name);
	}

	void sendExecuteMessage(string portalName, int maxRows)
	{
		stream.write('E');
		stream.write(cast(int)(4 + portalName.length + 1 + 4));
		stream.writeCString(portalName);
		stream.write(cast(int)maxRows);
	}

	void sendFlushMessage()
	{
		stream.write('H');
		stream.write(cast(int)4);
		stream.flush();
	}

	void sendSyncMessage()
	{
		stream.write('S');
		stream.write(cast(int)4);
		stream.flush();
	}

	ResponseMessage handleResponseMessage(Message msg)
	{
		enforce(msg.data.length >= 2);

		char ftype;
		string fvalue;
		ResponseMessage response = new ResponseMessage;

		while(true)
		{
			msg.read(ftype);
			if (ftype <= 0) break;
			msg.readCString(fvalue);
			response.fields[ftype] = fvalue;
		}

		return response;
	}

	void checkActiveResultSet()
	{
		enforce(!activeResultSet, "There's active result set, which must be closed first.");
	}

	void prepare(string statementName, string query, PGParameters params)
	{
		checkActiveResultSet();
		sendParseMessage(statementName, query, params.getOids());

		sendFlushMessage();

	receive:

		Message msg = getMessage();

		switch (msg.type)
		{
			case 'E':
				// ErrorResponse
				ResponseMessage response = handleResponseMessage(msg);
				sendSyncMessage();

				string details = response.toString();
				string* pos = 'P' in response.fields;
				if (pos && (*pos).to!size_t < query.length) {
					size_t idx = (*pos).to!size_t;
					size_t start;
					if (idx > 10)
						start = idx - 10;
					else start = 0;
					size_t end = min(query.length, idx + 20);
					details ~= "\n'" ~ query[start .. end].replace("\t", " ").replace("\n", " ").to!string ~ "'\n          ^";
				}
				throw new ServerErrorException("Could not execute query '" ~ query ~ "' => " ~ details);
			case '1':
				// ParseComplete
				return;
			default:
				// async notice, notification
				goto receive;
		}
	}

	void unprepare(string statementName)
	{
		checkActiveResultSet();
		sendCloseMessage(DescribeType.Statement, statementName);
		sendFlushMessage();

	receive:

		Message msg = getMessage();

		switch (msg.type)
		{
			case 'E':
				// ErrorResponse
				ResponseMessage response = handleResponseMessage(msg);
				throw new ServerErrorException(response);
			case '3':
				// CloseComplete
				return;
			default:
				// async notice, notification
				goto receive;
		}
	}

	PGFields bind(string portalName, string statementName, PGParameters params)
	{
		checkActiveResultSet();
		sendCloseMessage(DescribeType.Portal, portalName);
		sendBindMessage(portalName, statementName, params);
		sendDescribeMessage(DescribeType.Portal, portalName);
		sendFlushMessage();

	receive:

		Message msg = getMessage();

		switch (msg.type)
		{
			case 'E':
				// ErrorResponse
				ResponseMessage response = handleResponseMessage(msg);
				sendSyncMessage();

				throw new ServerErrorException(response);
			case '3':
				// CloseComplete
				goto receive;
			case '2':
				// BindComplete
				goto receive;
			case 'T':
				// RowDescription (response to Describe)
				PGField[] fields;
				short fieldCount;
				short formatCode;
				PGField fi;

				msg.read(fieldCount);

				fields.length = fieldCount;

				foreach (i; 0..fieldCount)
				{
					msg.readCString(fi.name);
					msg.read(fi.tableOid);
					msg.read(fi.index);
					msg.read(fi.oid);
					msg.read(fi.typlen);
					msg.read(fi.modifier);
					msg.read(formatCode);

					enforce(formatCode == 1, new Exception("Field's format code returned in RowDescription is not 1 (binary)"));

					fields[i] = fi;
				}

				return cast(PGFields)fields;
			case 'n':
				// NoData (response to Describe)
				return new immutable(PGField)[0];
			default:
				// async notice, notification
				goto receive;
		}
	}

	ulong executeNonQuery(string portalName, out uint oid)
	{
		checkActiveResultSet();
		ulong rowsAffected = 0;

		sendExecuteMessage(portalName, 0);
		sendSyncMessage();
		sendFlushMessage();

	receive:

		Message msg = getMessage();

		switch (msg.type)
		{
			case 'E':
				// ErrorResponse
				ResponseMessage response = handleResponseMessage(msg);
				throw new ServerErrorException(response);
			case 'D':
				// DataRow
				finalizeQuery();
				throw new Exception("This query returned rows.");
			case 'C':
				// CommandComplete
				string tag;

				msg.readCString(tag);

				// GDC indexOf name conflict in std.string and std.algorithm
				auto s1 = std.string.indexOf(tag, ' ');
				if (s1 >= 0) {
					switch (tag[0 .. s1]) {
						case "INSERT":
							// INSERT oid rows
							auto s2 = lastIndexOf(tag, ' ');
							assert(s2 > s1);
							oid = to!uint(tag[s1 + 1 .. s2]);
							rowsAffected = to!ulong(tag[s2 + 1 .. $]);
							break;
						case "DELETE", "UPDATE", "MOVE", "FETCH":
							// DELETE rows
							rowsAffected = to!ulong(tag[s1 + 1 .. $]);
							break;
						default:
							// CREATE TABLE
							break;
					}
				}

				goto receive;

			case 'I':
				// EmptyQueryResponse
				goto receive;
			case 'Z':
				// ReadyForQuery
				return rowsAffected;
			default:
				// async notice, notification
				goto receive;
		}
	}

	DBRow!Specs fetchRow(Specs...)(ref Message msg, ref PGFields fields)
	{
		alias DBRow!Specs Row;

		static if (Row.hasStaticLength)
		{
			alias Row.fieldTypes fieldTypes;

			static string genFieldAssigns() // CTFE
			{
				string s = "";

				foreach (i; 0 .. fieldTypes.length)
				{
					s ~= "msg.read(fieldLen);\n";
					s ~= "if (fieldLen == -1)\n";
					s ~= text("row.setNull!(", i, ")();\n");
					s ~= "else\n";
					s ~= text("row.set!(fieldTypes[", i, "], ", i, ")(",
						"msg.readBaseType!(fieldTypes[", i, "])(fields[", i, "].oid, fieldLen)",
						");\n");
					// text() doesn't work with -inline option, CTFE bug
				}

				return s;
			}
		}

		Row row;
		short fieldCount;
		int fieldLen;

		msg.read(fieldCount);

		static if (Row.hasStaticLength)
		{
			Row.checkReceivedFieldCount(fieldCount);
			mixin(genFieldAssigns);
		}
		else
		{
			row.setLength(fieldCount);

			foreach (i; 0 .. fieldCount)
			{
				msg.read(fieldLen);
				if (fieldLen == -1)
					row.setNull(i);
				else
					row[i] = msg.readBaseType!(Row.ElemType)(fields[i].oid, fieldLen);
			}
		}

		return row;
	}

	void finalizeQuery()
	{
		Message msg;

		do
		{
			msg = getMessage(true);

			// TODO: process async notifications
		}
		while (msg.type != 'Z'); // ReadyForQuery
	}

	PGResultSet!Specs executeQuery(Specs...)(string portalName, ref PGFields fields)
	{
		checkActiveResultSet();

		PGResultSet!Specs result = new PGResultSet!Specs(this, fields, &fetchRow!Specs);

		ulong rowsAffected = 0;

		sendExecuteMessage(portalName, 0);
		sendSyncMessage();
		sendFlushMessage();

	receive:

		Message msg = getMessage();

		switch (msg.type)
		{
			case 'D':
				// DataRow
				alias DBRow!Specs Row;

				result.row = fetchRow!Specs(msg, fields);
				static if (!Row.hasStaticLength)
					result.row.columnToIndex = &result.columnToIndex;
				result.validRow = true;
				result.nextMsg = getMessage();

				activeResultSet = true;

				return result;
			case 'C':
				// CommandComplete
				string tag;

				msg.readCString(tag);

				auto s2 = lastIndexOf(tag, ' ');
				if (s2 >= 0)
				{
					rowsAffected = to!ulong(tag[s2 + 1 .. $]);
				}

				goto receive;
			case 'I':
				// EmptyQueryResponse
				throw new Exception("Query string is empty.");
			case 's':
				// PortalSuspended
				throw new Exception("Command suspending is not supported.");
			case 'Z':
				// ReadyForQuery
				result.nextMsg = msg;
				return result;
			case 'E':
				// ErrorResponse
				ResponseMessage response = handleResponseMessage(msg);
				throw new ServerErrorException(response);
			default:
				// async notice, notification
				goto receive;
		}

		assert(0);
	}

public:


	/**
        Opens connection to server.

        Params:
        params = Associative array of string keys and values.

        Currently recognized parameters are:
        $(UL
            $(LI host - Host name or IP address of the server. Required.)
            $(LI port - Port number of the server. Defaults to 5432.)
            $(LI user - The database user. Required.)
            $(LI database - The database to connect to. Defaults to the user name.)
            $(LI options - Command-line arguments for the backend. (This is deprecated in favor of setting individual run-time parameters.))
        )

        In addition to the above, any run-time parameter that can be set at backend start time might be listed.
        Such settings will be applied during backend start (after parsing the command-line options if any).
        The values will act as session defaults.

        Examples:
        ---
        auto conn = new PGConnection([
            "host" : "localhost",
            "database" : "test",
            "user" : "postgres",
            "password" : "postgres"
        ]);
        ---
        */
	this(const string[string] params)
	{
		enforce("host" in params, new ParamException("Required parameter 'host' not found"));
		enforce("user" in params, new ParamException("Required parameter 'user' not found"));

		string[string] p = cast(string[string])params;

		ushort port = "port" in params? parse!ushort(p["port"]) : 5432;

		version(linux) {
			if (params["host"].startsWith("/"))
				stream = new PGStream(connectUDS(params["host"]));
			else
				stream = new PGStream(connectTCP(params["host"], port));
		} else stream = new PGStream(connectTCP(params["host"], port));
		if (auto ptr = "ssl" in params) {
			if (*ptr == "require") {
				import vibe.stream.tls : createTLSContext, createTLSStream;

				auto tlsContext = createTLSContext(TLSContextKind.client, TLSVersion.tls1_2);
				tlsContext.setClientALPN(["postgresql"]);
				auto tcp_conn = cast(TCPConnection) stream.socket();
				import vibe.stream.botan : BotanTLSStream;
				auto tlsStream = cast(BotanTLSStream)createTLSStream(tcp_conn, tlsContext, params["host"], tcp_conn.remoteAddress);
				tlsStream.processException();
				stream = new PGStream(tlsStream);
			}
		}
		sendStartupMessage(params);
		struct SaslSession {
			string mechanism;
			string clientNonce;
			string serverNonce;
			string salt;
			int iterations;
			string serverSignature;
		}
		SaslSession saslSession;
	receive:
		Message msg = getMessage();
		switch (msg.type)
		{
			case 'E', 'N':
				// ErrorResponse, NoticeResponse

				ResponseMessage response = handleResponseMessage(msg);

				if (msg.type == 'N')
					goto receive;

				throw new ServerErrorException(response);
			case 'R':
				// AuthenticationXXXX
				enforce(msg.data.length >= 4);

				int atype;

				msg.read(atype);

				switch (atype)
				{
					case 0:
						// authentication successful, now wait for another messages
						goto receive;
					case 3:
						// clear-text password is required
						enforce("password" in params, new ParamException("Required parameter 'password' not found"));
						enforce(msg.data.length == 4);

						sendPasswordMessage(params["password"]);

						goto receive;
					case 5:
						// MD5-hashed password is required, formatted as:
						// "md5" + md5(md5(password + username) + salt)
						// where md5() returns lowercase hex-string
						enforce("password" in params, new ParamException("Required parameter 'password' not found"));
						enforce(msg.data.length == 8);

						char[3 + 32] password;
						password[0 .. 3] = "md5";
						password[3 .. $] = MD5toHex(MD5toHex(params["password"], params["user"]), msg.data[4 .. 8]);

						sendPasswordMessage(to!string(password));

						goto receive;
					case 10:

						enforce("password" in params, new ParamException("Required parameter 'password' not found"));
						string[] mechanisms;
						bool found_scram_sha_256 = false;
						do {
							msg.readCString(saslSession.mechanism);
							mechanisms ~= saslSession.mechanism;
							if (saslSession.mechanism == "SCRAM-SHA-256") {
								found_scram_sha_256 = true;
								break;
							}
						} while (saslSession.mechanism.length > 0);
						enforce(found_scram_sha_256, new Exception("SCRAM-SHA-256 mechanism not found in " ~ mechanisms.to!string));

						saslSession.clientNonce = Base64.encode(random(18));
						string res = "n,,n="~params["user"]~",r=" ~ saslSession.clientNonce;
						int len = cast(int) (4 + saslSession.mechanism.length + 1 + 4 + res.length);
						stream.write('p');
						stream.write(len);
						stream.writeCString(saslSession.mechanism);
						stream.write(cast(int)res.length);
						stream.writeString(res);
						goto receive;
					case 11:

						enforce("password" in params, new ParamException("Required parameter 'password' not found"));
						string serverReply = msg.readString(cast(int)msg.data.length - 4);
						string[] buffer = serverReply.split(',').to!(string[]);
						string nonce, salt;
						int iterations;
						foreach(el; buffer) {
							switch(el[0]) {
								case 'r':
									nonce = el[2 .. $];
									break;
								case 's':
									salt = el[2 .. $];
									break;
								case 'i':
									iterations = to!int(el[2 .. $]);
									break;
								default:
									continue;
							}
						}
						enforce(nonce.length > 0 && salt.length > 0 && iterations > 0, new Exception("Invalid SCRAM-SHA-256 parameters in " ~ serverReply));

						enforce(nonce.startsWith(saslSession.clientNonce), new Exception("Invalid SCRAM-SHA-256 nonce"));	// client nonce must be prefix of server nonce

						auto saltedPassword = Hi(params["password"], Base64.decode(salt), iterations);
						auto clientKey = hmacSha256(saltedPassword, cast(ubyte[])"Client Key");
						auto storedKey = sha256Of(clientKey).dup;

						string clientFinalMessageWithoutProof = "c=biws,r=" ~ nonce;
						string authMessage = "n=" ~ params["user"] ~ ",r=" ~ saslSession.clientNonce ~ ",r=" ~ nonce ~ ",s=" ~ salt ~ ",i=" ~ to!string(iterations) ~ "," ~ clientFinalMessageWithoutProof;

						auto clientSignature = hmacSha256(storedKey, cast(ubyte[])authMessage);
						ubyte[] clientProof = xorBuffers(clientKey, clientSignature);
						auto res = clientFinalMessageWithoutProof ~ ",p=" ~ Base64.encode(clientProof);
						stream.write('p');
						stream.write(cast(int)(4 + res.length));
						stream.writeString(cast(string)res);

						goto receive;
					case 12:

						enforce("password" in params, new ParamException("Required parameter 'password' not found"));
						string serverReply = msg.readString(cast(int)msg.data.length - 4);
						string[] parts = serverReply.split(',');
						string serverSignature;
						foreach (part; parts) switch (part[0]) {
							case 'v':
								serverSignature = part[2 .. $];
								break;
							default: continue;
						}
						enforce(serverSignature.length > 0, new Exception("Invalid SCRAM-SHA-256 server signature"));
						//enforce(serverSignature == saslSession.serverSignature, new Exception("SCRAM-SHA-256 server signature mismatch"));
						goto receive;
/*
						// PostgreSQL SCRAM-SHA-256 authentication sequence
						void postgresqlScramSha256(string username, string password, string clientNonce) {
							import std.string;
							import std.array;
							import std.conv;
							import std.exception;
							// Step 1: Server sends salt and iteration count
							string salt = generateSalt();
							uint iterations = 4096;

							writeln("Server-first-message:");
							writeln("r=" ~ clientNonce ~ ",s=" ~ salt ~ ",i=" ~ to!string(iterations));

							// Step 2: Client processes server-first-message
							auto saltedPassword = pbkdf2(password, Base64.decode(salt), iterations, SHA256.size);
							auto clientKey = hmacSha256(saltedPassword, "Client Key");
							auto storedKey = SHA256.digest(clientKey);

							string clientFinalMessageWithoutProof = "c=biws,r=" ~ clientNonce;
							string authMessage = "n=" ~ username ~ ",r=" ~ clientNonce ~ ",s=" ~ salt ~ ",i=" ~ to!string(iterations) ~ "," ~ clientFinalMessageWithoutProof;

							auto clientSignature = hmacSha256(storedKey, authMessage);
							ubyte[] clientProof;
							foreach (i, b; clientKey) clientProof ~= b ^ clientSignature[i];

							writeln("Client-final-message:");
							writeln(clientFinalMessageWithoutProof ~ ",p=" ~ Base64.encode(clientProof));

							// Step 3: Server verifies client proof and responds
							auto serverKey = hmacSha256(saltedPassword, "Server Key");
							auto serverSignature = hmacSha256(serverKey, authMessage);

							writeln("Server-final-message:");
							writeln("v=" ~ Base64.encode(serverSignature));
						}
*/

					default:
						// non supported authentication type, close connection
						this.close();
						import std.conv : to;
						throw new Exception("Unsupported authentication type " ~ atype.to!string());
				}

			case 'S':
				// ParameterStatus
				enforce(msg.data.length >= 2);

				string pname, pvalue;

				msg.readCString(pname);
				msg.readCString(pvalue);

				serverParams[pname] = pvalue;

				goto receive;

			case 'K':
				// BackendKeyData
				enforce(msg.data.length == 8);

				msg.read(serverProcessID);
				msg.read(serverSecretKey);

				goto receive;

			case 'Z':
				// ReadyForQuery
				enforce(msg.data.length == 1);

				msg.read(cast(char)trStatus);

				// check for validity
				switch (trStatus)
				{
					case 'I', 'T', 'E': break;
					default: throw new Exception("Invalid transaction status");
				}

				// connection is opened and now it's possible to send queries
				reloadAllTypes();
				return;
			default:
				// unknown message type, ignore it
				goto receive;
		}
	}
	@property bool connected() {
		return stream.socket.connected;
	}
	/// Closes current connection to the server.
	void close()
	{
		sendTerminateMessage();
		stream.socket.close();
	}

	/// Shorthand methods using temporary PGCommand. Semantics is the same as PGCommand's.
	ulong executeNonQuery(string query)
	{
		scope cmd = new PGCommand(this, query);
		return cmd.executeNonQuery();
	}

	/// ditto
	PGResultSet!Specs executeQuery(Specs...)(string query)
	{
		scope cmd = new PGCommand(this, query);
		return cmd.executeQuery!Specs();
	}

	/// ditto
	DBRow!Specs executeRow(Specs...)(string query, bool throwIfMoreRows = true)
	{
		scope cmd = new PGCommand(this, query);
		return cmd.executeRow!Specs(throwIfMoreRows);
	}

	/// ditto
	T executeScalar(T)(string query, bool throwIfMoreRows = true)
	{
		scope cmd = new PGCommand(this, query);
		return cmd.executeScalar!T(throwIfMoreRows);
	}

	void reloadArrayTypes()
	{
		auto cmd = new PGCommand(this, "SELECT oid, typelem FROM pg_type WHERE typcategory = 'A'");
		auto result = cmd.executeQuery!(uint, "arrayOid", uint, "elemOid");
		scope(exit) result.destroy();
		arrayTypes = null;

		foreach (row; result)
		{
			arrayTypes[row.arrayOid] = row.elemOid;
		}

		arrayTypes.rehash;
	}

	void reloadCompositeTypes()
	{
		auto cmd = new PGCommand(this, "SELECT a.attrelid, a.atttypid FROM pg_attribute a JOIN pg_type t ON
                                     a.attrelid = t.typrelid WHERE a.attnum > 0 ORDER BY a.attrelid, a.attnum");
		auto result = cmd.executeQuery!(uint, "typeOid", uint, "memberOid");
		scope(exit) result.destroy();

		compositeTypes = null;

		uint lastOid = 0;
		uint[]* memberOids;

		foreach (row; result)
		{
			if (row.typeOid != lastOid)
			{
				compositeTypes[lastOid = row.typeOid] = new uint[0];
				memberOids = &compositeTypes[lastOid];
			}

			*memberOids ~= row.memberOid;
		}

		compositeTypes.rehash;
	}

	void reloadEnumTypes()
	{
		auto cmd = new PGCommand(this, "SELECT enumtypid, oid, enumlabel FROM pg_enum ORDER BY enumtypid, oid");
		auto result = cmd.executeQuery!(uint, "typeOid", uint, "valueOid", string, "valueLabel");
		scope(exit) result.destroy();

		enumTypes = null;

		uint lastOid = 0;
		string[uint]* enumValues;

		foreach (row; result)
		{
			if (row.typeOid != lastOid)
			{
				if (lastOid > 0)
					(*enumValues).rehash;

				enumTypes[lastOid = row.typeOid] = null;
				enumValues = &enumTypes[lastOid];
			}

			(*enumValues)[row.valueOid] = row.valueLabel;
		}

		if (lastOid > 0)
			(*enumValues).rehash;

		enumTypes.rehash;
	}

	void reloadAllTypes()
	{
		// todo: make simpler type lists, since we need only oids of types (without their members)
		reloadArrayTypes();
		reloadCompositeTypes();
		reloadEnumTypes();
	}
}

/// Class representing single query parameter
class PGParameter
{
	private PGParameters params;
	immutable short index;
	immutable PGType type;
	private Variant _value;

	/// Value bound to this parameter
	@property Variant value()
	{
		return _value;
	}
	/// ditto
	@property Variant value(T)(T v)
	{
		params.changed = true;
		return _value = Variant(v);
	}

	private this(PGParameters params, short index, PGType type)
	{
		enforce(index > 0, new ParamException("Parameter's index must be > 0"));
		this.params = params;
		this.index = index;
		this.type = type;
	}
}

/// Collection of query parameters
class PGParameters
{
	private PGParameter[short] params;
	private PGCommand cmd;
	private bool changed;

	private int[] getOids()
	{
		short[] keys = params.keys;
		sort(keys);

		int[] oids = new int[params.length];

		foreach (size_t i, key; keys)
		{
			oids[i] = params[key].type;
		}

		return oids;
	}

	///
	@property short length()
	{
		return cast(short)params.length;
	}

	private this(PGCommand cmd)
	{
		this.cmd = cmd;
	}

	/**
    Creates and returns new parameter.
    Examples:
    ---
    // without spaces between $ and number
    auto cmd = new PGCommand(conn, "INSERT INTO users (name, surname) VALUES ($ 1, $ 2)");
    cmd.parameters.add(1, PGType.TEXT).value = "John";
    cmd.parameters.add(2, PGType.TEXT).value = "Doe";

    assert(cmd.executeNonQuery == 1);
    ---
    */
	PGParameter add(short index, PGType type)
	{
		enforce(!cmd.prepared, "Can't add parameter to prepared statement.");
		changed = true;
		return params[index] = new PGParameter(this, index, type);
	}

	PGParameters bind(T)(short index, PGType type, T value)
	{
		enforce(!cmd.prepared, "Can't add parameter to prepared statement.");
		changed = true;
		params[index] = new PGParameter(this, index, type);
		params[index].value = value;
		return this;
	}

	// todo: remove()

	PGParameter opIndex(short index)
	{
		return params[index];
	}

	int opApply(int delegate(ref PGParameter param) dg)
	{
		int result = 0;

		foreach (number; sort(params.keys))
		{
			result = dg(params[number]);

			if (result)
				break;
		}

		return result;
	}
}

/// Array of fields returned by the server
alias immutable(PGField)[] PGFields;

/// Contains information about fields returned by the server
struct PGField
{
	/// The field name.
	string name;
	/// If the field can be identified as a column of a specific table, the object ID of the table; otherwise zero.
	uint tableOid;
	/// If the field can be identified as a column of a specific table, the attribute number of the column; otherwise zero.
	short index;
	/// The object ID of the field's data type.
	uint oid;
	/// The data type size (see pg_type.typlen). Note that negative values denote variable-width types.
	short typlen;
	/// The type modifier (see pg_attribute.atttypmod). The meaning of the modifier is type-specific.
	int modifier;
}

/// Class encapsulating prepared or non-prepared statements (commands).
class PGCommand
{
	private PGConnection conn;
	private string _query;
	private PGParameters params;
	private PGFields _fields = null;
	private string preparedName;
	private uint _lastInsertOid;
	private bool prepared;

	/// List of parameters bound to this command
	@property PGParameters parameters()
	{
		return params;
	}

	/// List of fields that will be returned from the server. Available after successful call to bind().
	@property PGFields fields()
	{
		return _fields;
	}

	/**
    Checks if this is query or non query command. Available after successful call to bind().
    Returns: true if server returns at least one field (column). Otherwise false.
    */
	@property bool isQuery()
	{
		enforce(_fields !is null, new Exception("bind() must be called first."));
		return _fields.length > 0;
	}

	/// Returns: true if command is currently prepared, otherwise false.
	@property bool isPrepared()
	{
		return prepared;
	}

	/// Query assigned to this command.
	@property string query()
	{
		return _query;
	}
	/// ditto
	@property string query(string query)
	{
		enforce(!prepared, "Can't change query for prepared statement.");
		return _query = query;
	}

	/// If table is with OIDs, it contains last inserted OID.
	@property uint lastInsertOid()
	{
		return _lastInsertOid;
	}

	this(PGConnection conn, string query = "")
	{
		this.conn = conn;
		_query = query;
		params = new PGParameters(this);
		_fields = new immutable(PGField)[0];
		preparedName = "";
		prepared = false;
	}

	/// Prepare this statement, i.e. cache query plan.
	void prepare()
	{
		enforce(!prepared, "This command is already prepared.");
		preparedName = conn.reservePrepared();
		conn.prepare(preparedName, _query, params);
		prepared = true;
		params.changed = true;
	}

	/// Unprepare this statement. Goes back to normal query planning.
	void unprepare()
	{
		enforce(prepared, "This command is not prepared.");
		conn.unprepare(preparedName);
		preparedName = "";
		prepared = false;
		params.changed = true;
	}

	/**
    Binds values to parameters and updates list of returned fields.

    This is normally done automatically, but it may be useful to check what fields
    would be returned from a query, before executing it.
    */
	void bind()
	{
		checkPrepared(false);
		_fields = conn.bind(preparedName, preparedName, params);
		params.changed = false;
	}

	private void checkPrepared(bool bind)
	{
		if (!prepared)
		{
			// use unnamed statement & portal
			conn.prepare("", _query, params);
			if (bind)
			{
				_fields = conn.bind("", "", params);
				params.changed = false;
			}
		}
	}

	private void checkBound()
	{
		if (params.changed)
			bind();
	}

	/**
    Executes a non query command, i.e. query which doesn't return any rows. Commonly used with
    data manipulation commands, such as INSERT, UPDATE and DELETE.
    Examples:
    ---
    auto cmd = new PGCommand(conn, "DELETE * FROM table");
    auto deletedRows = cmd.executeNonQuery;
    cmd.query = "UPDATE table SET quantity = 1 WHERE price > 100";
    auto updatedRows = cmd.executeNonQuery;
    cmd.query = "INSERT INTO table VALUES(1, 50)";
    assert(cmd.executeNonQuery == 1);
    ---
    Returns: Number of affected rows.
    */
	ulong executeNonQuery()
	{
		checkPrepared(true);
		checkBound();
		return conn.executeNonQuery(preparedName, _lastInsertOid);
	}

	/**
    Executes query which returns row sets, such as SELECT command.
    Params:
    bufferedRows = Number of rows that may be allocated at the same time.
    Returns: InputRange of DBRow!Specs.
    */
	PGResultSet!Specs executeQuery(Specs...)()
	{
		checkPrepared(true);
		checkBound();
		return conn.executeQuery!Specs(preparedName, _fields);
	}

	/**
    Executes query and returns only first row of the result.
    Params:
    throwIfMoreRows = If true, throws Exception when result contains more than one row.
    Examples:
    ---
    auto cmd = new PGCommand(conn, "SELECT 1, 'abc'");
    auto row1 = cmd.executeRow!(int, string); // returns DBRow!(int, string)
    assert(is(typeof(i[0]) == int) && is(typeof(i[1]) == string));
    auto row2 = cmd.executeRow; // returns DBRow!(Variant[])
    ---
    Throws: Exception if result doesn't contain any rows or field count do not match.
    Throws: Exception if result contains more than one row when throwIfMoreRows is true.
    */
	DBRow!Specs executeRow(Specs...)(bool throwIfMoreRows = true)
	{
		auto result = executeQuery!Specs();
		scope(exit) result.destroy();
		enforce(!result.empty(), "Result doesn't contain any rows.");
		auto row = result.front();
		if (throwIfMoreRows)
		{
			result.popFront();
			enforce(result.empty(), "Result contains more than one row.");
		}
		return row;
	}

	/**
    Executes query returning exactly one row and field. By default, returns Variant type.
    Params:
    throwIfMoreRows = If true, throws Exception when result contains more than one row.
    Examples:
    ---
    auto cmd = new PGCommand(conn, "SELECT 1");
    auto i = cmd.executeScalar!int; // returns int
    assert(is(typeof(i) == int));
    auto v = cmd.executeScalar; // returns Variant
    ---
    Throws: Exception if result doesn't contain any rows or if it contains more than one field.
    Throws: Exception if result contains more than one row when throwIfMoreRows is true.
    */
	T executeScalar(T = Variant)(bool throwIfMoreRows = true)
	{
		auto result = executeQuery!T();
		scope(exit) result.destroy();
		enforce(!result.empty(), "Result doesn't contain any rows.");
		T row = result.front();
		if (throwIfMoreRows)
		{
			result.popFront();
			enforce(result.empty(), "Result contains more than one row.");
		}
		return row;
	}
}

/// Input range of DBRow!Specs
class PGResultSet(Specs...)
{
	alias DBRow!Specs Row;
	alias Row delegate(ref Message msg, ref PGFields fields) FetchRowDelegate;

	private FetchRowDelegate fetchRow;
	private PGConnection conn;
	private PGFields fields;
	private Row row;
	private bool validRow;
	private Message nextMsg;
	private size_t[][string] columnMap;

	private this(PGConnection conn, ref PGFields fields, FetchRowDelegate dg)
	{
		this.conn = conn;
		this.fields = fields;
		this.fetchRow = dg;
		validRow = false;

		foreach (i, field; fields)
		{
			size_t[]* indices = field.name in columnMap;

			if (indices)
				*indices ~= i;
			else
				columnMap[field.name] = [i];
		}
	}
	~this() {
		if (conn && conn.activeResultSet) {
			close();
		}
	}
	private size_t columnToIndex(string column, size_t index)
	{
		size_t[]* indices = column in columnMap;
		enforce(indices, "Unknown column name");
		return (*indices)[index];
	}

	pure nothrow bool empty()
	{
		return !validRow;
	}

	void popFront()
	{
		if (nextMsg.type == 'D')
		{
			row = fetchRow(nextMsg, fields);
			static if (!Row.hasStaticLength)
				row.columnToIndex = &columnToIndex;
			validRow = true;
			nextMsg = conn.getMessage();
		}
		else
			validRow = false;
	}

	pure nothrow Row front()
	{
		return row;
	}

	/// Closes current result set. It must be closed before issuing another query on the same connection.
	void close()
	{
		if (nextMsg.type != 'Z')
			conn.finalizeQuery();
		conn.activeResultSet = false;
	}

	int opApply(int delegate(ref Row row) dg)
	{
		int result = 0;

		while (!empty)
		{
			result = dg(row);
			popFront;

			if (result)
				break;
		}

		return result;
	}

	int opApply(int delegate(ref size_t i, ref Row row) dg)
	{
		int result = 0;
		size_t i;

		while (!empty)
		{
			result = dg(i, row);
			popFront;
			i++;

			if (result)
				break;
		}

		return result;
	}
}

import vibe.core.connectionpool;

class PostgresDB {
	import memutils.scoped : ManagedPool;
	private {
		string[string] m_params;
		ConnectionPool!PGConnection m_pool;
	}

	this(string[string] conn_params)
	{
		m_params = conn_params.dup;
		m_pool = new ConnectionPool!PGConnection(&createConnection);
	}

	@property void maxConcurrency(uint val) { m_pool.maxConcurrency = val; }
	@property uint maxConcurrency() { return m_pool.maxConcurrency; }

	auto lockConnection() { return m_pool.lockConnection(); }

	private PGConnection createConnection()
	{
		auto pgconn = new PGConnection(m_params);
		if (auto ptr = "statement_timeout" in m_params) {
			auto stmt = scoped!PGCommand(pgconn, "SET statement_timeout = " ~ (*ptr));
			stmt.executeNonQuery();
		}
		return pgconn;
	}
}
