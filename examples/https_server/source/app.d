/**
	HTTPS example for vibe.0: Botan TLS, ECDSA P-256, TLSGC, optional workers.

	Same working condition as the ECDSA HS bench: P-256 cert, TLS 1.2 offer
	with max 1.3 (clients negotiate 1.3 + X25519), TLSGC per-thread freelist,
	HTTPServerOption.distribute + setupWorkerThreads. Field mul hits botan
	CurveGFpP256 Solinas redc. The four Botan TLS delegates stay frozen.
*/
import vibe.core.args;
import vibe.core.core;
import vibe.http.server;
import vibe.stream.tls;
import std.file : exists;
import std.stdio : stdout, writeln;

void handleRequest(scope HTTPServerRequest req, scope HTTPServerResponse res)
{
	res.writeBody(cast(ubyte[])"Hello, World!", "text/plain");
}

void main()
{
	ushort port = 8080;
	int workers = 1;
	string cert = "ecdsa.crt";
	string key = "ecdsa.key";
	readOption("port", &port, "listen port");
	readOption("workers", &workers, "OS worker threads (HTTPServerOption.distribute)");
	readOption("cert", &cert, "PEM certificate (default ecdsa.crt, P-256)");
	readOption("key", &key, "PEM private key (default ecdsa.key)");
	if (!finalizeCommandLineOptions())
		return;
	if (workers < 1) workers = 1;
	if (!exists(cert) || !exists(key)) {
		writeln("missing TLS cert/key: ", cert, " / ", key);
		return;
	}

	auto settings = new HTTPServerSettings;
	settings.port = port;
	settings.bindAddresses = ["::1", "127.0.0.1"];
	if (workers > 1) {
		setupWorkerThreads(workers);
		settings.options = settings.options | HTTPServerOption.distribute;
	}
	// OpenSSL-style tls1_2: min 1.2, max 1.3. botan latestTlsVersion stays 1.2.
	settings.tlsContext = createTLSContext(TLSContextKind.server, TLSVersion.tls1_2);
	settings.tlsContext.useCertificateChainFile(cert);
	settings.tlsContext.usePrivateKeyFile(key);

	listenHTTP(settings, &handleRequest);
	writeln("READY driver=vibe.0-botan port=", port, " workers=", workers, " cert=", cert);
	stdout.flush();
	runEventLoop();
}
