module app;

import vibe.core.core;
import vibe.core.log;
import vibe.core.net;
import vibe.stream.botan;
import vibe.stream.tls;
import botan.tls.version_;
import std.exception;
import std.conv : to;

void main()
{
	setLogLevel(LogLevel.info);

	auto any = createTLSContext(TLSContextKind.client, TLSVersion.any);
	auto botanAny = cast(BotanTLSContext) any;
	enforce(botanAny !is null, "factory any must be BotanTLSContext");
	enforce(TLSProtocolVersion.latestTlsVersion() == TLSProtocolVersion(TLSProtocolVersion.TLS_V12),
		"botan latestTlsVersion stays 1.2");
	enforce(botanAny.defaultProtocolOffer == TLSProtocolVersion(TLSProtocolVersion.TLS_V13),
		"any/tls1_2 offer is ossl-style max 1.3");

	auto offer13 = createTLSContext(TLSContextKind.client, TLSVersion.tls1_3);
	auto botan13 = cast(BotanTLSContext) offer13;
	enforce(botan13 !is null, "factory tls1_3 must be BotanTLSContext");
	enforce(botan13.defaultProtocolOffer == TLSProtocolVersion(TLSProtocolVersion.TLS_V13),
		"tls1_3 factory must offer TLS 1.3");

	auto creds = createCreds();
	auto serverCtx = new BotanTLSContext(TLSContextKind.server, TLSVersion.tls1_3, creds);
	auto clientCtx = new BotanTLSContext(TLSContextKind.client, TLSVersion.tls1_3);
	clientCtx.peerValidationMode = TLSPeerValidationMode.none;

	listenTCP(18443, (conn) {
		auto stream = createTLSStream(conn, serverCtx, TLSStreamState.accepting,
			"localhost", conn.remoteAddress);
		ubyte[5] buf;
		stream.read(buf);
		enforce(cast(string) buf == "hello", "server read: " ~ cast(string) buf);
		stream.write(cast(const(ubyte)[]) "world");
		stream.flush();
		stream.finalize();
		conn.close();
	});

	string negotiated;
	string suite;
	runTask({
		scope (exit) exitEventLoop();
		auto conn = connectTCP("127.0.0.1", 18443);
		auto stream = createTLSStream(conn, clientCtx, "localhost", conn.remoteAddress);
		auto botan = cast(BotanTLSStream) stream;
		enforce(botan !is null, "expected BotanTLSStream");
		enforce(botan.protocol == TLSProtocolVersion(TLSProtocolVersion.TLS_V13),
			"negotiated " ~ botan.protocol.toString());
		negotiated = botan.protocol.toString();
		suite = botan.cipher.toString();
		stream.write(cast(const(ubyte)[]) "hello");
		stream.flush();
		ubyte[5] buf;
		stream.read(buf);
		enforce(cast(string) buf == "world", "client read: " ~ cast(string) buf);
		stream.finalize();
		conn.close();
		logInfo("TLS 1.3 loopback OK: %s %s", negotiated, suite);
	});

	runEventLoop();
	enforce(negotiated == "TLS v1.3", "did not negotiate TLS 1.3");
}
