/**
	Downloading and uploading of data from/to URLs.

	Copyright: © 2012 Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibe.inet.urltransfer;

import vibe.core.log;
import vibe.core.file;
import vibe.http.client;
import vibe.inet.url;
import vibe.core.stream;

import std.exception;
import std.string;
import std.datetime.stopwatch : StopWatch;
import std.datetime;
import memutils.utils;
import memutils.unique;


/**
	Downloads a file from the specified URL.

	Any redirects will be followed until the actual file resource is reached or if the redirection
	limit of 10 is reached. Note that only HTTP(S) is currently supported.
*/
void download(URL url, scope void delegate(scope InputStream) callback, HTTPClient client = null, void delegate(CountedStream) on_connect = null)
{
	assert(url.username.length == 0 && url.password.length == 0, "Auth not supported yet.");
	assert(url.schema == "http" || url.schema == "https", "Only http(s):// supported for now.");

	if(!client) client = new HTTPClient();
	scope(exit) client.disconnect(false);
	foreach( i; 0 .. 10 ){
		bool ssl = url.schema == "https";
		client.connect(url.host, url.port ? url.port : ssl ? 443 : 80, ssl);
		//logTrace("connect to %s", url.host);
		bool done = false;
		client.request(
			(scope HTTPClientRequest req) {
				if (on_connect) {
					if (auto conn = cast(CountedStream)req.topConnection)
						on_connect(conn);
				}
				req.requestURL = url.localURI;
				req.headers["Accept-Encoding"] = "gzip";
				//logTrace("REQUESTING %s!", req.requestURL);
			},
			(scope HTTPClientResponse res) {
				//logTrace("GOT ANSWER!");

				switch( res.statusCode ){
					default:
						throw new HTTPStatusException(res.statusCode, format("Server responded with %s for %s", httpStatusText(res.statusCode), url));
					case HTTPStatus.OK:
						done = true;
						callback(res.bodyReader);
						break;
					case HTTPStatus.movedPermanently:
					case HTTPStatus.found:
					case HTTPStatus.seeOther:
					case HTTPStatus.temporaryRedirect:
						//logTrace("Status code: %s", res.statusCode);
						auto pv = "Location" in res.headers;
						enforce(pv !is null, format("Server responded with redirect but did not specify the redirect location for %s", url));
						logDebug("Redirect to '%s'", *pv);
						if( startsWith((*pv), "http:") || startsWith((*pv), "https:") ){
						//logTrace("parsing %s", *pv);
							url = URL(*pv);
						} else url.localURI = *pv;
						break;
				}
			}
		);
		if (done) return;
		else {
			import vibe.core.core : sleep;
			import std.datetime : seconds;
			sleep(5.seconds);
		}
	}
	enforce(false, "Too many redirects!");
	assert(false);
}

/// ditto
void download(string url, scope void delegate(scope InputStream) callback, HTTPClient client = null, void delegate(CountedStream) on_connect = null)
{
	return download(URL(url), callback, client, on_connect);
}

/// ditto
void download(string url, string filename, scope void delegate(ulong kbps) poll_speed = null)
{
	CountedStream conn;

	void onConnect(CountedStream _conn) { conn = _conn; }

	void handler(scope InputStream input)
	{
		auto fil = openFile(filename, FileMode.createTrunc);
		scope(exit) fil.close();

		ubyte[] buffer = ThreadMem.alloc!(ubyte[])(64*1024);
		scope(exit) ThreadMem.free(buffer);

		//logTrace("default write %d bytes, empty=%s", nbytes, stream.empty);
		while( !input.empty ){
			import std.algorithm : min;
			size_t chunk = min(input.leastSize, buffer.length);
			enforce(chunk > 0, "leastSize returned zero for non-empty stream.");
			//logTrace("read pipe chunk %d", chunk);
			ulong bytes_start;
			StopWatch sw;
			if (poll_speed) { bytes_start = conn.received; sw.start(); }
			input.read(buffer[0 .. chunk]);
			if (poll_speed)
			{
				ulong diff = conn.received - bytes_start;
				sw.stop();
				import std.algorithm : max;
				ulong msecs = max(1, cast(ulong)sw.peek().total!"msecs");
				poll_speed(cast(ulong) ((diff/msecs) * 8));
			}
			fil.write(buffer[0 .. chunk]);
		}
	}

	download(url, &handler, null, &onConnect);
}

/// ditto
void download(URL url, Path filename, scope void delegate(ulong kbps) poll_speed = null)
{
	return download(url.toString(), filename.toNativeString(), poll_speed);
}
