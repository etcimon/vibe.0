/**
	Zlib input/output streams

	Copyright: © 2012-2013 Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibe.stream.zlib;

import vibe.core.stream;
import vibe.utils.array;
import memutils.circularbuffer;

import std.algorithm;
import std.exception;
import etc.c.zlib;

import vibe.core.log;
import memutils.utils;

/**
	Writes any data compressed in deflate format to the specified output stream.
*/
final class DeflateOutputStream : ZlibOutputStream {
	this(OutputStream dst, int level = Z_DEFAULT_COMPRESSION, bool nowrap = false)
	{
		super(dst, HeaderFormat.deflate, level, nowrap);
	}
}


/**
	Writes any data compressed in gzip format to the specified output stream.
*/
final class GzipOutputStream : ZlibOutputStream {
	this(OutputStream dst, int level = Z_DEFAULT_COMPRESSION, bool nowrap = false)
	{
		super(dst, HeaderFormat.gzip, level, nowrap);
	}
}

/**
	Generic zlib output stream.
*/
class ZlibOutputStream : OutputStream {
	private {
		OutputStream m_out;
		z_stream m_zstream;
		ubyte[] m_outbuffer;
		//ubyte[4096] m_inbuffer;
		bool m_finalized = false;
	}

	enum HeaderFormat {
		gzip,
		deflate
	}

	this(OutputStream dst, HeaderFormat type, int level = Z_DEFAULT_COMPRESSION, bool nowrap = false)
	{
		m_outbuffer = ThreadMem.alloc!(ubyte[])(1024);
		m_out = dst;
		int max_wbits = 15 + (type == HeaderFormat.gzip ? 16 : 0);
		zlibEnforce(deflateInit2(&m_zstream, level, Z_DEFLATED, nowrap ? -max_wbits : max_wbits, 8, Z_DEFAULT_STRATEGY));
	}

	~this() {
		//import std.stdio : writeln;
		//writeln("ZLib output");
		if (!m_finalized)
			finalize();
	}

	final void write(in ubyte[] data)
	{
		if (!data.length) return;
		assert(!m_finalized);
		assert(m_zstream.avail_in == 0);
		m_zstream.next_in = cast(ubyte*)data.ptr;
		assert(data.length < uint.max);
		m_zstream.avail_in = cast(uint)data.length;
		doFlush(Z_NO_FLUSH);
		assert(m_zstream.avail_in == 0);
		m_zstream.next_in = null;
	}

	final void write(InputStream stream, ulong nbytes = 0)
	{
		writeDefault(stream, nbytes);
	}

	final void flush()
	{
		assert(!m_finalized);
		//doFlush(Z_SYNC_FLUSH);
	}

	final void finalize()
	{
		if (m_finalized) return;
		scope(exit)
			ThreadMem.free(m_outbuffer);

		try doFlush(Z_FINISH); catch (ConnectionClosedException) {}
		zlibEnforce(deflateEnd(&m_zstream));
		m_finalized = true;
	}

	private final void doFlush(int how)
	{
		while (true) {
			m_zstream.next_out = m_outbuffer.ptr;
			m_zstream.avail_out = cast(uint)m_outbuffer.length;
			//logInfo("deflate %s -> %s (%s)", m_zstream.avail_in, m_zstream.avail_out, how);
			auto ret = deflate(&m_zstream, how);
			//logInfo("    ... %s -> %s", m_zstream.avail_in, m_zstream.avail_out);
			switch (ret) {
				default:
					zlibEnforce(ret);
					assert(false, "Unknown return value for zlib deflate.");
				case Z_OK:
					assert(m_zstream.avail_out < m_outbuffer.length || m_zstream.avail_in == 0);
					m_out.write(m_outbuffer[0 .. m_outbuffer.length - m_zstream.avail_out]);
					break;
				case Z_BUF_ERROR:
					assert(m_zstream.avail_in == 0);
					return;
				case Z_STREAM_END:
					assert(how == Z_FINISH);
					m_out.write(m_outbuffer[0 .. m_outbuffer.length - m_zstream.avail_out]);
					return;
			}
		}
	}
}


/**
	Takes an input stream that contains data in deflate compressed format and outputs the
	uncompressed data.
*/
class DeflateInputStream : ZlibInputStream {
	this(InputStream dst, bool nowrap = false)
	{
		super(dst, HeaderFormat.deflate, nowrap);
	}
}


/**
	Takes an input stream that contains data in gzip compressed format and outputs the
	uncompressed data.
*/
class GzipInputStream : ZlibInputStream {
	this(InputStream dst, bool nowrap = false)
	{
		super(dst, HeaderFormat.gzip, nowrap);
	}
}


/**
	Generic zlib input stream.
*/
class ZlibInputStream : InputStream {
	import std.zlib;
	private {
		InputStream m_in;
		z_stream m_zstream;
		CircularBuffer!(ubyte, 4096) m_outbuffer;
		ubyte[] m_inbuffer;
		bool m_finished = false;
		ulong m_ninflated, n_read;
	}

	enum HeaderFormat {
		gzip,
		deflate,
		automatic
	}

	this(InputStream src, HeaderFormat type, bool nowrap = false)
	{
		m_inbuffer = ThreadMem.alloc!(ubyte[])(1024);
		m_in = src;
		if (!m_in || m_in.empty) {
			m_finished = true;
		} else {
			int wndbits = 15;
			if(type == HeaderFormat.gzip) wndbits += 16;
			else if(type == HeaderFormat.automatic) wndbits += 32;
			if (nowrap) wndbits = -wndbits;
			zlibEnforce(inflateInit2(&m_zstream, wndbits));
			readChunk();
		}
	}

	~this() {
		//import std.stdio : writeln;
		//writeln("ZLib input");
		if (!m_finished) {
			inflateEnd(&m_zstream);
			ThreadMem.free(m_inbuffer);
		}
	}

	@property bool empty() { return this.leastSize == 0; }

	@property ulong leastSize()
	{
		assert(!m_finished || m_in.empty, "Input contains more data than expected.");
		if (m_outbuffer.length > 0) return m_outbuffer.length;
		if (m_finished) return 0;
		readChunk();
		//assert(m_outbuffer.length || m_finished);
		return m_outbuffer.length;
	}

	@property bool dataAvailableForRead()
	{
		return m_outbuffer.length > 0;
	}

	const(ubyte)[] peek() { return m_outbuffer.peek(); }

	void read(ubyte[] dst)
	{
		enforce(dst.length == 0 || !empty, "Reading empty stream");

		while (dst.length > 0) {
			auto len = min(m_outbuffer.length, dst.length);
			m_outbuffer.read(dst[0 .. len]);
			dst = dst[len .. $];

			if (!m_outbuffer.length && !m_finished) readChunk();
			enforce(dst.length == 0 || !m_finished, "Reading past end of zlib stream.");
		}
	}

	void readChunk()
	{
		assert(m_outbuffer.length == 0, "Buffer must be empty to read the next chunk.");
		assert(m_outbuffer.peekDst().length > 0);
		enforce (!m_finished, "Reading past end of zlib stream.");

		m_zstream.next_out = m_outbuffer.peekDst().ptr;
		m_zstream.avail_out = cast(uint)m_outbuffer.peekDst().length;

		while (!m_outbuffer.length) {
			if (m_zstream.avail_in == 0) {
				auto clen = min(m_inbuffer.length, m_in.leastSize);
				if (clen == 0) {
					m_finished = true;
					return;
				}
				m_in.read(m_inbuffer[0 .. clen]);
				m_zstream.next_in = m_inbuffer.ptr;
				m_zstream.avail_in = cast(uint)clen;
			}
			auto avins = m_zstream.avail_in;
			//logInfo("inflate %s -> %s (@%s in @%s)", m_zstream.avail_in, m_zstream.avail_out, m_ninflated, n_read);
			auto ret = zlibEnforce(inflate(&m_zstream, Z_SYNC_FLUSH));
			//logInfo("    ... %s -> %s", m_zstream.avail_in, m_zstream.avail_out);
			assert(m_zstream.avail_out != m_outbuffer.peekDst.length || m_zstream.avail_in != avins);
			m_ninflated += m_outbuffer.peekDst().length - m_zstream.avail_out;
			n_read += avins - m_zstream.avail_in;
			m_outbuffer.putN(m_outbuffer.peekDst().length - m_zstream.avail_out);
			//logDebug("Inflated: %s", cast(string)m_outbuffer.peek());
			assert(m_zstream.avail_out == 0 || m_zstream.avail_out == m_outbuffer.peekDst().length);

			if (ret == Z_STREAM_END) {
				m_finished = true;
				scope(exit)
					ThreadMem.free(m_inbuffer);
				zlibEnforce(inflateEnd(&m_zstream));
				assert(m_in.empty, "Input expected to be empty at this point.");
				return;
			}
		}
	}
}

private int zlibEnforce(int result)
{
	switch (result) {
		default:
			if (result < 0) throw new Exception("unknown zlib error");
			else return result;
		case Z_ERRNO: throw new Exception("zlib errno error");
		case Z_STREAM_ERROR: throw new Exception("zlib stream error");
		case Z_DATA_ERROR: throw new Exception("zlib data error");
		case Z_MEM_ERROR: throw new Exception("zlib memory error");
		case Z_BUF_ERROR: throw new Exception("zlib buffer error");
		case Z_VERSION_ERROR: throw new Exception("zlib version error");
	}
}