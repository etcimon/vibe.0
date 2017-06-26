/**
	Zlib input/output streams

	Copyright: © 2012-2013 RejectedSoftware e.K.
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibe.stream.brotli;

import vibe.core.stream;
import vibe.utils.array;
import vibe.utils.memory;
import memutils.circularbuffer;

import std.algorithm;
import std.exception;
import vibe.data.brotli;

import vibe.core.log;
import memutils.utils;

/**
	Brotli output stream.
*/
/*
class BrotliOutputStream : OutputStream {
	private {
		OutputStream m_out;
		z_stream m_bstream;
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
		brotliEnforce(deflateInit2(&m_bstream, level, Z_DEFLATED, nowrap ? -max_wbits : max_wbits, 8, Z_DEFAULT_STRATEGY));
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
		assert(m_bstream.avail_in == 0);
		m_bstream.next_in = cast(ubyte*)data.ptr;
		assert(data.length < uint.max);
		m_bstream.avail_in = cast(uint)data.length;
		doFlush(Z_NO_FLUSH);
		assert(m_bstream.avail_in == 0);
		m_bstream.next_in = null;
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
		brotliEnforce(deflateEnd(&m_bstream));
		m_finalized = true;
	}

	private final void doFlush(int how)
	{
		while (true) {
			m_bstream.next_out = m_outbuffer.ptr;
			m_bstream.avail_out = cast(uint)m_outbuffer.length;
			//logInfo("deflate %s -> %s (%s)", m_bstream.avail_in, m_bstream.avail_out, how);
			auto ret = deflate(&m_bstream, how);
			//logInfo("    ... %s -> %s", m_bstream.avail_in, m_bstream.avail_out);
			switch (ret) {
				default:
					brotliEnforce(ret);
					assert(false, "Unknown return value for zlib deflate.");
				case Z_OK:
					assert(m_bstream.avail_out < m_outbuffer.length || m_bstream.avail_in == 0);
					m_out.write(m_outbuffer[0 .. m_outbuffer.length - m_bstream.avail_out]);
					break;
				case Z_BUF_ERROR:
					assert(m_bstream.avail_in == 0);
					return;
				case Z_STREAM_END:
					assert(how == Z_FINISH);
					m_out.write(m_outbuffer[0 .. m_outbuffer.length - m_bstream.avail_out]);
					return;
			}
		}
	}
}
*/
/**
	Brotli input stream.
*/
class BrotliInputStream : InputStream {
	private {
		InputStream m_in;
		BrotliDecoderState* m_bstream;
		CircularBuffer!(ubyte, 4096) m_outbuffer;
		ubyte[] m_inbuffer;
		bool m_finished = false;
		size_t m_ninflated, n_read;
		size_t avail_in_data;
		size_t* avail_in;
		const(ubyte)* next_in_data;
		const(ubyte)** next_in;
	}

	this(InputStream src)
	{
		m_inbuffer = ThreadMem.alloc!(ubyte[])(1024);
		m_in = src;
		avail_in = &avail_in_data;
		if (!m_in || m_in.empty) {
			m_finished = true;
		} else {
			brotliEnforce(m_bstream = BrotliDecoderCreateInstance(null, null, &m_bstream));
			readChunk();
		}
	}

	~this() {
		//import std.stdio : writeln;
		//writeln("ZLib input");
		if (!m_finished) {
			BrotliDecoderDestroyInstance(m_bstream);
			ThreadMem.free(m_inbuffer);
		}
	}

	@property bool empty() { return this.leastSize == 0; }

	@property ulong leastSize()
	{
		assert(!m_finished || m_in.empty, "Input contains more data than expected.");
		//logInfo("leastsize: %d", m_outbuffer.length);
		//logInfo("m_finished: %s", m_finished?"true":"false");
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
		//logInfo("readChunk");
		assert(m_outbuffer.length == 0, "Buffer must be empty to read the next chunk.");
		assert(m_outbuffer.peekDst().length > 0);
		enforce (!m_finished, "Reading past end of br stream.");
		ubyte* next_out_data = m_outbuffer.peekDst().ptr;
		ubyte** next_out = &next_out_data;
		size_t avail_out_data = m_outbuffer.peekDst().length;
		size_t* avail_out = &avail_out_data;
		while (!m_outbuffer.length) {
			if (*avail_in == 0) {
				//logInfo("*avail_in == 0");
				auto clen = min(m_inbuffer.length, m_in.leastSize);
				if (clen == 0 && BrotliDecoderIsFinished(m_bstream)) {
					//logInfo("clen == 0 (%d, %d)",m_inbuffer.length, m_in.leastSize);
					m_finished = true;
					return;
				}
				if (clen > 0) m_in.read(m_inbuffer[0 .. clen]);
				next_in_data = m_inbuffer.ptr;
				next_in = &next_in_data;
				*avail_in = clen;
			}
			size_t avins = *avail_in;
			//logInfo("inflate %s -> %s (@%s in @%s)", *avail_in, *avail_out, m_ninflated, n_read);

			auto ret = brotliEnforce(BrotliDecoderDecompressStream(m_bstream, avail_in, next_in, avail_out, next_out, &m_ninflated));
			//logInfo("    ... %s -> %s [%d]", *avail_in, *avail_out, m_ninflated);
			assert(*avail_out != m_outbuffer.peekDst.length || *avail_in != avins);
			n_read += avins - *avail_in;
			m_outbuffer.putN(m_outbuffer.peekDst().length - *avail_out);
			//logDebug("Inflated: %s", cast(string)m_outbuffer.peek());
			assert(*avail_out == 0 || *avail_out == m_outbuffer.peekDst().length);

			if (ret == BrotliDecoderResult.BROTLI_DECODER_RESULT_SUCCESS && BrotliDecoderIsFinished(m_bstream)) {
				m_finished = true;
				scope(exit)
					ThreadMem.free(m_inbuffer);
				//logInfo("Finished");
				BrotliDecoderDestroyInstance(m_bstream);
				assert(m_in.empty, "Input expected to be empty at this point.");
				return;
			}
		}
	}

	private int brotliEnforce(int result)
	{
		import std.string : fromStringz;
		if (result == 0) {
			throw new Exception(cast(string) BrotliDecoderErrorString(BrotliDecoderGetErrorCode(m_bstream)).fromStringz());
		}
		return result;
	}
	private BrotliDecoderState* brotliEnforce(BrotliDecoderState* result)
	{
		import std.string : fromStringz;
		if (result is null) {
			throw new Exception(cast(string) BrotliDecoderErrorString(BrotliDecoderGetErrorCode(m_bstream)).fromStringz());
		}
		return result;
	}
}
