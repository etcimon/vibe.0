import vibe.appmain;
import vibe.http.server;
import vibe.stream.tls;
import vibe.stream.botan;
import vibe.core.log;
import vibe.core.core;
import libasync.threads;
import std.datetime;

void handleRequest(scope HTTPServerRequest req, scope HTTPServerResponse res)
{
	if (req.path == "/")
		res.writeBody("Hello, World!", "text/plain");
}

void main()
{
	setLogLevel(LogLevel.trace);
	auto settings = new HTTPServerSettings;
	settings.port = 4343;
	settings.disableHTTP2 = true;
	settings.bindAddresses = ["::1", "127.0.0.1"];
	listenHTTP(settings, &handleRequest);
	runEventLoop();
}
