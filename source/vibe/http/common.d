/**
	Common classes for HTTP clients and servers.

	Copyright: © 2012 Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig, Jan Krüger
*/
module vibe.http.common;

public import vibe.http.status;

import vibe.core.log;
import vibe.core.net;
import vibe.inet.message;
import vibe.stream.operations;
import vibe.stream.tls : TLSStream;
import vibe.http.http2 : HTTP2Stream;
import vibe.utils.array;
import vibe.utils.string;

import std.algorithm;
import std.array;
import std.range;
import std.conv;
import std.datetime;
import std.exception;
import std.format;
import std.string;
import std.typecons;

import memutils.vector;

enum HTTPVersion {
	HTTP_1_0,
	HTTP_1_1,
	HTTP_2
}


enum HTTPMethod {
	// HTTP standard
	GET,
	HEAD,
	PUT,
	POST,
	PATCH,
	DELETE,
	OPTIONS,
	TRACE,
	CONNECT,

	// WEBDAV extensions
	COPY,
	LOCK,
	MKCOL,
	MOVE,
	PROPFIND,
	PROPPATCH,
	UNLOCK,
	REPORT
}


/**
	Returns the string representation of the given HttpMethod.
*/
string httpMethodString(HTTPMethod m)
{
	return to!string(m);
}

/**
	Returns the HttpMethod value matching the given HTTP method string.
*/
HTTPMethod httpMethodFromString(string str)
{
	switch(str){
		default: throw new Exception("Invalid HTTP method: "~str);
		case "GET": return HTTPMethod.GET;
		case "HEAD": return HTTPMethod.HEAD;
		case "PUT": return HTTPMethod.PUT;
		case "POST": return HTTPMethod.POST;
		case "PATCH": return HTTPMethod.PATCH;
		case "DELETE": return HTTPMethod.DELETE;
		case "OPTIONS": return HTTPMethod.OPTIONS;
		case "TRACE": return HTTPMethod.TRACE;
		case "CONNECT": return HTTPMethod.CONNECT;
		case "COPY": return HTTPMethod.COPY;
		case "LOCK": return HTTPMethod.LOCK;
		case "MKCOL": return HTTPMethod.MKCOL;
		case "MOVE": return HTTPMethod.MOVE;
		case "PROPFIND": return HTTPMethod.PROPFIND;
		case "PROPPATCH": return HTTPMethod.PROPPATCH;
		case "UNLOCK": return HTTPMethod.UNLOCK;
		case "REPORT": return HTTPMethod.REPORT;
	}
}

unittest
{
	assert(httpMethodString(HTTPMethod.GET) == "GET");
	assert(httpMethodString(HTTPMethod.UNLOCK) == "UNLOCK");
	assert(httpMethodFromString("GET") == HTTPMethod.GET);
	assert(httpMethodFromString("UNLOCK") == HTTPMethod.UNLOCK);
}


/**
	Utility function that throws a HTTPStatusException if the _condition is not met.
*/
T enforceHTTP(T)(T condition, HTTPStatus statusCode, lazy string message = null, string file = __FILE__, typeof(__LINE__) line = __LINE__)
{
	return enforce(condition, new HTTPStatusException(statusCode, message, file, line));
}

/**
	Utility function that throws a HTTPStatusException with status code "400 Bad Request" if the _condition is not met.
*/
T enforceBadRequest(T)(T condition, lazy string message = null, string file = __FILE__, typeof(__LINE__) line = __LINE__)
{
	return enforceHTTP(condition, HTTPStatus.badRequest, message, file, line);
}


/**
	Represents an HTTP request made to a server.
*/
class HTTPRequest {

	public {
		/// The HTTP protocol version used for the request
		HTTPVersion httpVersion = HTTPVersion.HTTP_1_1;

		/// The HTTP _method of the request
		HTTPMethod method = HTTPMethod.GET;

		/** The request URL

			Note that the request URL usually does not include the global
			'http://server' part, but only the local path and a query string.
			A possible exception is a proxy server, which will get full URLs.
		*/
		string requestURL = "/";

		/// All request _headers
		InetHeaderMap headers;
	}

	protected this()
	{
	}

	public override string toString()
	{
		return httpMethodString(method) ~ " " ~ requestURL ~ " " ~ getHTTPVersionString(httpVersion);
	}


	/** Shortcut to the 'Host' header (always present for HTTP 1.1)
	*/
	@property string host() const { auto ph = "Host" in headers; return ph ? *ph : null; }
	/// ditto
	@property void host(string v) { headers["Host"] = v; }

	/** Returns the mime type part of the 'Content-Type' header.

		This function gets the pure mime type (e.g. "text/plain")
		without any supplimentary parameters such as "charset=...".
		Use contentTypeParameters to get any parameter string or
		headers["Content-Type"] to get the raw value.
	*/
	@property string contentType()
	const {
		auto pv = "Content-Type" in headers;
		if( !pv ) return null;
		auto idx = std.string.indexOf(*pv, ';');
		return idx >= 0 ? (*pv)[0 .. idx] : *pv;
	}
	/// ditto
	@property void contentType(string ct) { headers["Content-Type"] = ct; }

	/** Returns any supplementary parameters of the 'Content-Type' header.

		This is a semicolon separated ist of key/value pairs. Usually, if set,
		this contains the character set used for text based content types.
	*/
	@property string contentTypeParameters()
	const {
		auto pv = "Content-Type" in headers;
		if( !pv ) return null;
		auto idx = std.string.indexOf(*pv, ';');
		return idx >= 0 ? (*pv)[idx+1 .. $] : null;
	}

	/** Determines if the connection persists across requests.
	*/
	@property bool persistent() const
	{
		if (auto ph = "connection" in headers)
		{
			final switch(httpVersion) {
				case HTTPVersion.HTTP_1_0:
					if (icmp2(*ph, "keep-alive") == 0) return true;
					return false;
				case HTTPVersion.HTTP_1_1:
					if (icmp2(*ph, "close") == 0) return false;
					return true;
				case HTTPVersion.HTTP_2:
					return false;
			}
		}

		final switch(httpVersion) {
			case HTTPVersion.HTTP_1_0:
				return false;
			case HTTPVersion.HTTP_1_1:
				return true;
			case HTTPVersion.HTTP_2:
				return false;
		}
	}
}


/**
	Represents the HTTP response from the server back to the client.
*/
class HTTPResponse {
	public {
		/// The protocol version of the response - should not be changed
		HTTPVersion httpVersion = HTTPVersion.HTTP_1_1;

		/// The status code of the response, 200 by default
		int statusCode = HTTPStatus.OK;

		/** The status phrase of the response

			If no phrase is set, a default one corresponding to the status code will be used.
		*/
		string statusPhrase;

		/// The response header fields
		InetHeaderMap headers;

		/// All cookies that shall be set on the client for this request
		Cookie[string] cookies;
	}

	public override string toString()
	{
		auto app = appender!string();
		formattedWrite(app, "%s %d %s", getHTTPVersionString(this.httpVersion), this.statusCode, this.statusPhrase);
		return app.data;
	}

	/** Shortcut to the "Content-Type" header
	*/
	@property string contentType() const { auto pct = "Content-Type" in headers; return pct ? *pct : "application/octet-stream"; }
	/// ditto
	@property void contentType(string ct) { headers["Content-Type"] = ct; }
}


/**
	Respresents a HTTP response status.

	Throwing this exception from within a request handler will produce a matching error page.
*/
class HTTPStatusException : Exception {
	private {
		int m_status;
	}

	this(int status, string message = null, string file = __FILE__, int line = __LINE__, Throwable next = null)
	{
		super(message != "" ? message : httpStatusText(status), file, line, next);
		m_status = status;
	}

	/// The HTTP status code
	@property int status() const { return m_status; }

	string debugMessage;
}


final class MultiPart {
	string contentType;

	InputStream stream;
	//JsonValue json;
	string[string] form;
}

import vibe.core.core;
/// The client multipart requires the full size to be known beforehand in the Content-Length header.
/// For this reason, we require the underlying data to be of type RandomAccessStream
abstract class MultiPartPart {
	import vibe.stream.memory : MemoryStream;
	private MultiPartPart m_sibling;
	private	string m_boundary;
	// todo: MultiPartPart child;
	protected {
		MemoryStream m_headers;
		RandomAccessStream m_data;
	}

	@property MultiPartPart addSibling(MultiPartPart part)
	{
		part.m_boundary = m_boundary;
		MultiPartPart sib;
		for (sib = this; sib && sib.m_sibling; sib = sib.m_sibling)
			continue;
		sib.m_sibling = part;
		return this;
	}

	this(ref InetHeaderMap headers, string boundary) {
		headers.resolveBoundary(boundary);
		m_boundary = boundary;
	}

	final @property ulong size() { return m_headers.size + m_data.size + (m_sibling ? m_sibling.size + "\r\n".length : (m_boundary.length + "\r\n----\r\n".length)); }

	final string peek(bool first = true)
	{
		Appender!string app;
		if (!first)
			app ~= "\r\n";
		app ~= cast(string)m_headers.readAll();
		m_headers.seek(0);
		app ~= cast(string)m_data.readAll();
		m_data.seek(0);
		if (m_sibling)
			app ~= m_sibling.peek(false);
		else { // we're done
			app ~= "\r\n--";
			app ~= m_boundary;
			app ~= "--\r\n";
		}
		return app.data;
	}

	final void read(OutputStream sink, bool first = true) {
		if (!first)
			sink.write("\r\n");
		sink.write(m_headers);
		sink.write(m_data);
		finalize();
		if (m_sibling)
			m_sibling.read(sink, false);
		else { // we're done
			sink.write("\r\n--");
			sink.write(m_boundary);
			sink.write("--\r\n");
		}
	}

	void finalize();

}

final class CustomMultiPart : MultiPartPart
{
	this(ref InetHeaderMap headers, string multipart_headers, ubyte[] data, string boundary = null) {
		super(headers, boundary);
		m_headers = new MemoryStream(cast(ubyte[])multipart_headers, false);
		m_data = new MemoryStream(data, false);
	}

	this(ref InetHeaderMap headers, string multipart_headers, string data, string boundary = null) {
		this(headers, multipart_headers, cast(ubyte[]) data, boundary);
	}

	override void finalize() {
	}
}

final class FileMultiPart : MultiPartPart
{
	import vibe.core.file : openFile, FileStream;
	import vibe.inet.mimetypes : getMimeTypeForFile;

	this(ref InetHeaderMap headers, string field_name, string file_path, string boundary = null, string content_type = null) {

		super(headers, boundary);
		import std.path : baseName;
		Appender!string app;
		m_data = openFile(file_path);
		if (!content_type) {
			content_type = getMimeTypeForFile(file_path);
			if (content_type == "text/plain")
				content_type ~= "; charset=UTF-8";
		}
		// we generate the headers here because we need the payload size to be available at all times.
		app ~= "--";
		app ~= m_boundary;
		app ~= "\r\n";
		app ~= "Content-Length: ";
		app ~= m_data.size().to!string;
		app ~= "\r\n";
		app ~= "Content-Type: ";
		app ~= content_type;
		app ~= "\r\n";
		app ~= "Content-Disposition: form-data; name=\"";
		app ~= field_name;
		app ~= "\"; filename=\"";
		app ~= baseName(file_path);
		app ~= "\"\r\n";
		app ~= "Content-Transfer-Encoding: binary\r\n\r\n";

		m_headers = new MemoryStream(cast(ubyte[])app.data, false);
	}

	override void finalize() {
		(cast(FileStream)m_data).close();
	}


}

final class MemoryMultiPart : MultiPartPart
{
	this(ref InetHeaderMap headers, string field_name, ubyte[] form_data, string boundary = null, string charset = "UTF-8") {
		super(headers, boundary);

		/*headers*/{
			Appender!string app;
			// we generate the headers here because we need the payload size to be available at all times.
			app ~= "--";
			app ~= m_boundary;
			app ~= "\r\n";
			app ~= "Content-Type: text/plain; charset=";
			app ~= charset;
			app ~= "\r\n";
			app ~= "Content-Disposition: form-data; name=\"";
			app ~= field_name;
			app ~= "\"\r\n";
			app ~= "Content-Transfer-Encoding: 8bit\r\n\r\n";

			m_headers = new MemoryStream(cast(ubyte[])app.data, false);
		}

		/*data*/{
			m_data = new MemoryStream(form_data, false);
		}

	}

	override void finalize() {
	}
}

string getBoundary(ref InetHeaderMap headers)
{
	string boundary;
	if (headers.get("Content-Type", "").indexOf("boundary=", CaseSensitive.no) == -1)
		return null;
	auto content_type = headers["Content-Type"];
	boundary = content_type[content_type.indexOf("boundary=", CaseSensitive.no) + "boundary=".length .. $];
	if (boundary.indexOf(";") != -1) {
		boundary = boundary[0 .. boundary.indexOf(";")];
	}
	return boundary;
}

private void resolveBoundary(ref InetHeaderMap headers, ref string boundary)
{
	if (headers.get("Content-Type", "").indexOf("boundary", CaseSensitive.no) == -1) {
		if (!boundary) { // by default, we create a boundary
			import std.uuid : randomUUID;
			boundary = randomUUID().toString();
		}
		// and we assign it into the headers
		headers["Content-Type"] = "multipart/form-data; boundary=" ~ boundary;
	}
	else {
		if (!boundary)  // by default, we extract the boundary from the headers
			boundary = headers.getBoundary();
	}
}

string getHTTPVersionString(HTTPVersion ver)
{
	final switch(ver){
		case HTTPVersion.HTTP_1_0: return "HTTP/1.0";
		case HTTPVersion.HTTP_1_1: return "HTTP/1.1";
		case HTTPVersion.HTTP_2: return "HTTP/2";
	}
}


HTTPVersion parseHTTPVersion(ref string str)
{
	enforceBadRequest(str.startsWith("HTTP/"));
	str = str[5 .. $];
	int majorVersion = parse!int(str);
	enforceBadRequest(str.startsWith("."));
	str = str[1 .. $];
	int minorVersion = parse!int(str);

	enforceBadRequest( majorVersion == 1 && (minorVersion == 0 || minorVersion == 1) );
	return minorVersion == 0 ? HTTPVersion.HTTP_1_0 : HTTPVersion.HTTP_1_1;
}


/**
	Takes an input stream that contains data in HTTP chunked format and outputs the raw data.
*/
final class ChunkedInputStream : InputStream {
	private {
		InputStream m_in;
		ulong m_bytesInCurrentChunk = 0;
	}

	this(InputStream stream)
	{
		assert(stream !is null);
		m_in = stream;
		readChunk();
	}

	@property bool empty() const { return m_bytesInCurrentChunk == 0; }

	@property ulong leastSize() const { return m_bytesInCurrentChunk; }

	@property bool dataAvailableForRead() { return m_bytesInCurrentChunk > 0 && m_in.dataAvailableForRead; }

	const(ubyte)[] peek()
	{
		auto dt = m_in.peek();
		return dt[0 .. min(dt.length, m_bytesInCurrentChunk)];
	}

	void read(ubyte[] dst)
	{
		enforceBadRequest(!empty, "Read past end of chunked stream.");
		while( dst.length > 0 ){
			enforceBadRequest(m_bytesInCurrentChunk > 0, "Reading past end of chunked HTTP stream.");

			auto sz = cast(size_t)min(m_bytesInCurrentChunk, dst.length);
			m_in.read(dst[0 .. sz]);
			dst = dst[sz .. $];
			m_bytesInCurrentChunk -= sz;

			if( m_bytesInCurrentChunk == 0 ){
				// skip current chunk footer and read next chunk
				ubyte[2] crlf;
				m_in.read(crlf);
				enforceBadRequest(crlf[0] == '\r' && crlf[1] == '\n');
				readChunk();
			}
		}
	}

	private void readChunk()
	{
		assert(m_bytesInCurrentChunk == 0);
		// read chunk header
		//logTrace("read next chunk header");
		auto ln = cast(string)m_in.readLine();
		//logTrace("got chunk header: %s", ln);
		m_bytesInCurrentChunk = parse!ulong(ln, 16u);

		if( m_bytesInCurrentChunk == 0 ){
			// empty chunk denotes the end
			// skip final chunk footer
			ubyte[2] crlf;
			m_in.read(crlf);
			enforceBadRequest(crlf[0] == '\r' && crlf[1] == '\n');
		}
	}
}


/**
	Outputs data to an output stream in HTTP chunked format.
*/
final class ChunkedOutputStream : OutputStream {
	private {
		OutputStream m_out;
		Vector!ubyte m_buffer;
		size_t m_maxBufferSize = 512*1024;
		ulong m_bytesWritten;
		bool m_finalized = false;
	}

	this(OutputStream stream)
	{
		m_out = stream;
	}

	/** Maximum buffer size used to buffer individual chunks.

		A size of zero means unlimited buffer size. Explicit flush is required
		in this case to empty the buffer.
	*/
	@property size_t maxBufferSize() const { return m_maxBufferSize; }
	/// ditto
	@property void maxBufferSize(size_t bytes) { m_maxBufferSize = bytes; if (m_buffer.length >= m_maxBufferSize) flush(); }

	@property ulong bytesWritten() { return m_bytesWritten; }

	void write(in ubyte[] bytes_)
	{
		assert(!m_finalized);
		const(ubyte)[] bytes = bytes_;
		while (bytes.length > 0) {
			auto sz = bytes.length;
			if (m_maxBufferSize > 0 && m_maxBufferSize < m_buffer.length + sz)
				sz = m_maxBufferSize - min(m_buffer.length, m_maxBufferSize);
			if (sz > 0) {
				m_buffer.put(bytes[0 .. sz]);
				bytes = bytes[sz .. $];
			}
			if (bytes.length > 0)
				flush();
		}
	}

	void write(InputStream data, ulong nbytes = 0)
	{
		assert(!m_finalized);
		if( m_buffer.length > 0 ) flush();
		if( nbytes == 0 ){
			while( !data.empty ){
				auto sz = data.leastSize;
				assert(sz > 0);
				writeChunkSize(sz);
				m_out.write(data, sz);
				m_out.write("\r\n");
				m_bytesWritten += "\r\n".length;
				m_out.flush();
			}
		} else {
			writeChunkSize(nbytes);
			m_out.write(data, nbytes);
			m_out.write("\r\n");
			m_bytesWritten += "\r\n".length;
			m_out.flush();
		}
	}

	void flush()
	{
		assert(!m_finalized);
		auto data = m_buffer[];
		if( data.length ){
			writeChunkSize(data.length);
			m_out.write(data);
			m_out.write("\r\n");
		}
		m_out.flush();
		m_buffer.clear();
	}

	void finalize()
	{
		if (m_finalized) return;
		flush();
		m_buffer = Vector!ubyte();
		m_finalized = true;
		m_out.write("0\r\n\r\n");
		m_bytesWritten += "0\r\n\r\n".length;
		m_out.flush();
	}
	private void writeChunkSize(long length)
	{
		import vibe.stream.wrapper;
		auto rng = StreamOutputRange(m_out);
		formattedWrite(&rng, "%x\r\n", length);
		m_bytesWritten += length + rng.length;
	}
}

final class Cookie {
	private {
		string m_value;
		string m_domain;
		string m_path;
		string m_expires;
		long m_maxAge;
		bool m_secure;
		bool m_httpOnly;
	}

	@property void value(string value) { m_value = value; }
	@property string value() const { return m_value; }

	@property void domain(string value) { m_domain = value; }
	@property string domain() const { return m_domain; }

	@property void path(string value) { m_path = value; }
	@property string path() const { return m_path; }

	@property void expires(string value) { m_expires = value; }
	@property string expires() const { return m_expires; }

	@property void maxAge(long value) { m_maxAge = value; }
	@property long maxAge() const { return m_maxAge; }

	@property void secure(bool value) { m_secure = value; }
	@property bool secure() const { return m_secure; }

	@property void httpOnly(bool value) { m_httpOnly = value; }
	@property bool httpOnly() const { return m_httpOnly; }

	string toString(string name = "Cookie") {
		Appender!string dst;
		writeString(dst, name);
		return dst.data;
	}

	void writeString(R)(R dst, string name, bool encode = true)
		if (isOutputRange!(R, char))
	{
		import vibe.textfilter.urlencode;
		dst.put(name);
		dst.put('=');
		if (encode)
			filterURLEncode(dst, this.value);
		else
			dst.put(this.value);
		if (this.domain && this.domain != "") {
			dst.put("; Domain=");
			dst.put(this.domain);
		}
		if (this.path != "") {
			dst.put("; Path=");
			dst.put(this.path);
		}
		if (this.expires != "") {
			dst.put("; Expires=");
			dst.put(this.expires);
		}
		if (this.maxAge) dst.formattedWrite("; Max-Age=%s", this.maxAge);
		if (this.secure) dst.put("; Secure");
		if (this.httpOnly) dst.put("; HttpOnly");
	}
}


/**
*/
struct CookieValueMap {
	struct Cookie {
		string name;
		string value;
	}

	private {
		Cookie[] m_entries;
	}

	string get(string name, string def_value = null)
	const {
		auto pv = name in this;
		if( !pv ) return def_value;
		return *pv;
	}

	string[] getAll(string name)
	const {
		string[] ret;
		foreach(c; m_entries)
			if( c.name == name )
				ret ~= c.value;
		return ret;
	}

	void opIndexAssign(string value, string name)
	{
		m_entries ~= Cookie(name, value);
	}

	string opIndex(string name)
	const {
		import core.exception : RangeError;
		auto pv = name in this;
		if( !pv ) throw new RangeError("Non-existent cookie: "~name);
		return *pv;
	}

	int opApply(scope int delegate(ref Cookie) del)
	{
		foreach(ref c; m_entries)
			if( auto ret = del(c) )
				return ret;
		return 0;
	}

	int opApply(scope int delegate(ref Cookie) del)
	const {
		foreach(Cookie c; m_entries)
			if( auto ret = del(c) )
				return ret;
		return 0;
	}

	int opApply(scope int delegate(ref string name, ref string value) del)
	{
		foreach(ref c; m_entries)
			if( auto ret = del(c.name, c.value) )
				return ret;
		return 0;
	}

	int opApply(scope int delegate(ref string name, ref string value) del)
	const {
		foreach(Cookie c; m_entries)
			if( auto ret = del(c.name, c.value) )
				return ret;
		return 0;
	}

	inout(string)* opBinaryRight(string op)(string name) inout if(op == "in")
	{
		foreach(ref c; m_entries)
			if( c.name == name ) {
				static if (__VERSION__ < 2066)
					return cast(inout(string)*)&c.value;
				else
					return &c.value;
			}
		return null;
	}
}

interface CookieStore
{
	/// Send the '; '-joined concatenation of the cookies corresponding to the URL into sink
	void get(string host, string path, bool secure, void delegate(string) send_to) const;

	/// Send each matching cookie value individually to the specified sink
	void get(string host, string path, bool secure, void delegate(string[]) send_to) const;

	/// Sets the cookies using the provided Set-Cookie: header value entry
	void set(string host, string set_cookie);
}
