vibe.0 is a high-performance asynchronous I/O, concurrency and web application toolkit written in D. It achieves more than 2x higher throughput vs Nginx in benchmarks, using the HTTP static server example at `examples/http_static_server`.

It has forked off Vibe.d in 2015 and shares only the same core, with some additions to make it fully capable of developing mobile, desktop and server applications:

- Integrates with libasync for event loop and networking
- Unix File Sockets
- PostgreSQL support
- DOM/XML Parsing support
- CookieJars
- TLS 1.3 through OpenSSL
- Full Botan crypto suite integration
- Uses memutils for all memory operations
- Thrives to avoid all GC allocations internally
- Daemonize library embedded for launching as background services in windows or daemons in linux
- SQLite integration

It doesn't use @safe, which I believe only makes the code unreadable due to having to use @trusted everywhere.

**INSTALLATION**

The deimos openssl library is patched to enable http/2. You should use a local one until the PR merges at https://github.com/D-Programming-Deimos/openssl/pull/115

`git clone https://github.com/etcimon/openssl/tree/http2fix openssl`
`dub add-local openssl`

Also, you need to add a `"DeimosOpenSSL_3_0"` under your dub `versions` to select the OpenSSL build.

In the `vibe.0` package, under Windows you must change the `"libs-windows-x86_64"` and `"libs-windows-x86"` paths to your local ones

A sample `versions` array in a project dub.sdl file would look like: `versions "VibeCustomMain" "DisableDebugger" "VibeNoDebug" "SQLite" "TLSGC" "VibeRequestDebugger" "VibeDebugCatchAll" "DeimosOpenSSL_3_0"`

The `VibeRequestDebugger` allows using a `mixin(Trace)` to follow execution

An example `dub.sdl` project would have:
```
name "my-app-server"
description "The remote end server."
copyright "Copyright © 2025, My Company Inc"
authors "Etienne"
dependency "vibe-0" version="~>1.1.0"
dependency "memutils" version="~>1.0.0"
dependency "botan" version="~>1.13.0"
dependency "dmaxminddb" version="~>0.1.2"
targetType "executable"
targetName "my-app-server"
targetPath "."
versions "VibeCustomMain" "DisableDebugger" "VibeNoDebug" "SQLite" "TLSGC" "VibeRequestDebugger" "VibeDebugCatchAll" "DeimosOpenSSL_3_0"
```


An example `app.d` would have: 

```D

import vibe.d;
import vibe.core.core;
import vibe.http.proxy;
import vibe.stream.botan;
import vibe.db.redis.sessionstore;
import vibe.web.web;
import botan.cert.x509.x509cert;
import botan.pubkey.pkcs8;
import botan.rng.auto_rng;
import botan.tls.session_manager;
import botan.tls.version_;
import botan.tls.policy;
import std.algorithm : endsWith;
import std.datetime: seconds;

import api;

void main()
{
	Unique!AutoSeededRNG rng = new AutoSeededRNG;

	//// Open Endpoints
	WebInterfaceSettings isettings = new WebInterfaceSettings;
	router.registerWebInterface(new InstallationAPI, isettings);

	//// User API
	WebInterfaceSettings usettings = new WebInterfaceSettings;
	usettings.urlPrefix = "/api/";
	router.registerWebInterface(new UserAPI, usettings);

	//// Reverse Proxy
	HTTPReverseProxySettings proxy_settings = new HTTPReverseProxySettings;
	proxy_settings.destinationHost = "localhost";
	proxy_settings.destinationPort = 5173; // some Vite enabled NodeJS dev server
	proxy_settings.secure = false;
	proxy_settings.clientSettings = new HTTPClientSettings;
	proxy_settings.clientSettings.defaultKeepAliveTimeout = 20.seconds;
	proxy_settings.clientSettings.http2.disable = true;
	router.get("*", reverseProxyRequest(proxy_settings));


	//// Setup HTTPS Server
	HTTPServerSettings settings = new HTTPServerSettings;
	settings.sessionIdCookie = "myapp.sessid";
	settings.serverString = "My App Server";
	settings.port = 8080;
	settings.disableHTTP2 = false;
	settings.useCompressionIfPossible = true;
	settings.sessionStore = new RedisSessionStore("localhost", 0);
	(cast(RedisSessionStore) settings.sessionStore).expirationTime = 7.days;
	settings.bindAddresses = ["localhost", "::", "0.0.0.0"];
	debug {} else settings.options ^= HTTPServerOption.errorStackTraces; // disable error stack traces (Production builds)
	
	//// Configure TLS
	auto cert = X509Certificate("certs/cert.crt");
	//auto cacert = X509Certificate("ca.crt");
	auto pkey = loadKey("certs/private.pem", *rng, "pwrd128");
	auto creds = new CustomTLSCredentials(cert, X509Certificate.init, pkey);
	//auto policy = new LightTLSPolicy;
	auto tls_sess_man = new TLSSessionManagerInMemory(*rng); 
	// Preserve sessions in a SQLite database (Production)
	// new TLSSessionManagerSQLite("some_password", *rng, "tls_sessions.db", 150000, 2.days);
	BotanTLSContext tls_ctx = new BotanTLSContext(TLSContextKind.server, creds, null, tls_sess_man);
	tls_ctx.defaultProtocolOffer = TLSProtocolVersion.latestTlsVersion();
	settings.tlsContext = tls_ctx;
	//// Start Server
	listenHTTP(settings, router);
	runEventLoop();
}
```

A sample `api.d` file would have: 

```D

module api;

import helpers;
import std.string : toLower;
import std.random : uniform;
import std.exception : enforce;
import std.array : Appender;
import vibe.db.pgsql.pgsql;
import vibe.db.redis.redis;

private PostgresDB g_pgdb;
private RedisClient g_redisClient;

auto connectDB()
{
	if (!g_pgdb)
	{
		import std.random : uniform;

		version (Windows)
		{
			auto params = [
				"host": "127.0.0.1",
				"database": "mydatabase",
				"user": "postgres",
				"password": "xxxxxxxxx",
				"ssl": "require",
				"statement_timeout": "90000"
			];

		}
		else
		{
			auto params = [
				"host": "/tmp/.s.PGSQL.5432",
				"database": "slideshow3dai",
				"user": "root",
				"statement_timeout": "90000"
			];
		}
		g_pgdb = new PostgresDB(params);
		g_pgdb.maxConcurrency = 10;
		//auto pgconn = g_pgdb.lockConnection();
		//auto upd = scoped!PGCommand(pgconn, "SET statement_timeout = 90000");
		//upd.executeNonQuery();
	}

	return g_pgdb.lockConnection();
}

RedisDatabase connectCache()
{
	if (!g_redisClient)
	{
		version (Windows)
		{
			g_redisClient = connectRedis("127.0.0.1:6379");
		}
		else
		{
			g_redisClient = connectRedis("/tmp/redis.sock");
		}
	}
	return g_redisClient.getDatabase(0);
}

class InstallationAPI
{

	@path("/download/:guid/:filename")
	void getFile(scope HTTPServerRequest req, scope HTTPServerResponse res)
	{
		mixin(Trace); // see vibe.core.core: All error pages will show elements of this stack trace if enabled. Works in release builds.
		string filename = req.params.get("filename", null);
		enforceBadRequest(filename !is null);
		// todo: Store these in the database
		FileStream file = openFile("downloads/" ~ filename);
		scope (exit)
			file.close();
		res.headers["Content-Length"] = file.size.to!string;
		res.contentType = "application/octet-stream";
		res.bodyWriter.write(file);
	}
}


class UserAPI
{
	SessionVar!(long, "user_id") m_userid;
	private enum auth = before!authenticate("_userid");

	this()
	{
	}

	@auth @path("/get_user_id")
	void getUserID(scope HTTPServerRequest req, scope HTTPServerResponse res, long _userid)
	{
		res.writeBody(`{"user_id": ` ~ _userid.to!string ~ `}`);
	}

private:
	public mixin PrivateAccessProxy;

	long authenticate(scope HTTPServerRequest req, scope HTTPServerResponse res)
	{
		res.setDefaultHeaders();
		struct ErrorMessage
		{
			string message;
			int status;
		}

		if (!req.session)
			req.session = res.startSession("/", SessionOption.httpOnly, 365.days);
		long userid = m_userid;
		if (userid == 0)
		{
			res.writeJsonBody(ErrorMessage("Invalid user session", 403), HTTPStatus.forbidden);
		}
		return userid;
	}

  void setDefaultHeaders(scope HTTPServerResponse res)
  {
  	// IE workarounds for cache
  	res.headers["Cache-Control"] = "no-cache, no-store, must-revalidate";
  	res.headers["Pragma"] = "no-cache";
  	res.headers["Expires"] = "0";
  }

}

```

