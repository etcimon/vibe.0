import vibe.core.log;
import vibe.http.client;

import vibe.d;
import std.datetime;
import std.stdio : writeln;


shared static this()
{
	HTTPClientSettings settings = new HTTPClientSettings;
	settings.http2.disable = true;
	//setLogFile("test.txt", LogLevel.trace);
	setTimer(1.seconds, {
			foreach (int i; 0 .. 100) {

						requestHTTP("http://globecsys.com/",
							(scope req) {
								req.headers["Connection"] = "keep-alive";
							},
							(scope res) {
								res.dropBody();
							}, settings
						);
						writeln(i);
					
			}
		});
}
