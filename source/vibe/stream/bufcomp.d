module vibe.stream.bufcomp;

version(Botan):

import botan.algo_base.buf_comp : BufferedComputation;
import vibe.utils.memory;
import std.algorithm : min;
import vibe.core.stream;
import botan.codec.hex;

/// Reads the InputStream in the given BufferedComputation and returns a hex encoded string for transport
string computeHex(InputStream stream, BufferedComputation computer)
{
	static struct Buffer { ubyte[64*1024] bytes = void; }
	auto bufferobj = FreeListRef!(Buffer, false)();
	auto buffer = bufferobj.bytes[];
	
	//logTrace("default write %d bytes, empty=%s", nbytes, stream.empty);
	while( !stream.empty ){
		size_t chunk = min(stream.leastSize, buffer.length);
		assert(chunk > 0, "leastSize returned zero for non-empty stream.");
		//logTrace("read pipe chunk %d", chunk);
		stream.read(buffer[0 .. chunk]);
		computer.update(buffer[0 .. chunk]);
	}

	return computer.finished().hexEncode();

}

/// returns hex string of sha256 of a file
string sha256Of(string file_path) {
	import botan.hash.sha2_32 : SHA256;
	Unique!SHA256 sha256 = new SHA256();
	FileStream fstream = openFile(file_path);
	scope(exit) fstream.close();
	return fstream.compute(*sha256);
}