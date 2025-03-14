/**
	HTTP (reverse) proxy implementation

	Copyright: © 2012 Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibe.http.proxy;

import vibe.core.log;
import vibe.http.client;
import vibe.http.server;
import vibe.inet.message;
import vibe.stream.operations;

import std.conv;
import std.exception;
import std.string : format;
import std.conv : to;
import std.datetime : seconds;
import vibe.core.core;
import vibe.textfilter.urlencode;
import vibe.http.websockets;
import vibe.core.task : InterruptException;


/*
	TODO:
		- use a client pool
		- implement a path based reverse proxy
		- implement a forward proxy
*/

/**
	Transparently forwards all requests to the proxy to a destination_host.

	You can use the hostName field in the 'settings' to combine multiple internal HTTP servers
	into one public web server with multiple virtual hosts.
*/
void listenHTTPReverseProxy(HTTPServerSettings settings, HTTPReverseProxySettings proxy_settings)
{
	// disable all advanced parsing in the server
	settings.options = HTTPServerOption.none;
	listenHTTP(settings, reverseProxyRequest(proxy_settings));
}
/// ditto
void listenHTTPReverseProxy(HTTPServerSettings settings, string destination_host, ushort destination_port)
{
	auto proxy_settings = new HTTPReverseProxySettings;
	proxy_settings.destinationHost = destination_host;
	proxy_settings.destinationPort = destination_port;
	listenHTTPReverseProxy(settings, proxy_settings);
}


/**
	Returns a HTTP request handler that forwards any request to the specified host/port.
*/
HTTPServerRequestDelegateS reverseProxyRequest(HTTPReverseProxySettings settings)
{
	mixin(Trace);
	static immutable string[] non_forward_headers = ["te", "Content-Length", "Transfer-Encoding", "Content-Encoding", "Connection"];
	static InetHeaderMap non_forward_headers_map;
	if (non_forward_headers_map.length == 0)
		foreach (n; non_forward_headers)
			non_forward_headers_map[n] = "";

	URL url;
	url.schema = settings.secure?"https":"http";
	url.host = settings.destinationHost;
	url.port = settings.destinationPort;
	url.ip = settings.destinationIP;
	bool can_retry = true;
	void handleRequest(scope HTTPServerRequest req, scope HTTPServerResponse res)
	{
		mixin(Trace);
		auto rurl = url;
		rurl.localURI = req.requestURL;
		//logTrace("Enter proxy");
		void setupClientRequest(scope HTTPClientRequest creq)
		{
			mixin(Trace);
			creq.method = req.method;
			if ("Connection" in creq.headers) req.headers["Connection"] = creq.headers["Connection"] == "keep-alive" ? (settings.clientSettings.defaultKeepAliveTimeout ? "keep-alive" : "close") : creq.headers["Connection"];
			if ("Upgrade" in creq.headers) req.headers["Upgrade"] = creq.headers["Upgrade"];
			if ("HTTP2-Settings" in creq.headers) req.headers["HTTP2-Settings"] = creq.headers["HTTP2-Settings"];
			creq.headers = req.headers.clone();

			foreach (k, v; creq.headers) {
				if ((k == "" || k == "Sec-WebSocket-Extensions") && k in creq.headers) {
					creq.headers.remove(k);
				}
			}

			foreach (k, v; settings.defaultHeaders) {
				creq.headers[k] = v;
			}

			creq.headers["Host"] = format("%s%s", settings.destinationHost, settings.destinationPort == 80 ? "" : format("%s%s", ":", settings.destinationPort.to!string));
			if (settings.avoidCompressedRequests && "Accept-Encoding" in creq.headers)
				creq.headers.remove("Accept-Encoding");
			if (!settings.anonymous) {
				if (auto pfh = "X-Forwarded-Host" !in creq.headers) creq.headers["X-Forwarded-Host"] = req.headers["Host"];
				if (auto pfp = "X-Forwarded-Proto" !in creq.headers) creq.headers["X-Forwarded-Proto"] = req.tls ? "https" : "http";
				if (auto pff = "X-Forwarded-For" in req.headers) creq.headers["X-Forwarded-For"] = *pff ~ ", " ~ req.peer;
				else creq.headers["X-Forwarded-For"] = req.peer;
			}
			import vibe.data.json;
			if (!req.bodyReader.empty) {
				can_retry = false;
				creq.bodyWriter.write(req.bodyReader);
			}
			else if (req.json.type != Json.Type.undefined) {
				auto json_payload = req.json.toString();
				creq.headers["Content-Length"] = json_payload.length.to!string;
				creq.writeBody(cast(ubyte[])json_payload);
			}
			else if (req.form.length > 0) {
				import vibe.inet.webform : formEncode;
				string req_form_string = formEncode(req.form);
				creq.headers["Content-Length"] = req_form_string.length.to!string;
				creq.headers["Content-Type"] = "application/x-www-form-urlencoded";
				creq.writeBody(cast(ubyte[])req_form_string);
			}
			foreach (k, v; creq.headers) {
				logDebug("Header: %s: %s", k, v);
			}
			enforce(!req.files.length, "File upload through proxy is not supported");
		}

		void handleClientResponse(scope HTTPClientResponse cres)
		{
			mixin(Trace);
			import vibe.utils.string;

			foreach (k, v; settings.defaultResponseHeaders) {
				res.headers[k] = v;
			}

			// copy the response to the original requester
			res.statusCode = cres.statusCode;
			if (can_retry && cres.statusCode == HTTPStatus.internalServerError && "Content-Length" in cres.headers)
				enforce(cres.headers["Content-Length"] != "0", "Unhandled Exception");
			// special case for empty response bodies
			if (cres.isFinalized) {
				foreach (key, value; cres.headers) {
					if (icmp2(key, "Connection") != 0) {
						res.headers[key] = value;
						break;
					}
				}
				if ("Content-Length" in res.headers)
					res.headers.remove("Content-Length");
				if ("Transfer-Encoding" in res.headers)
					res.headers.remove("Transfer-Encoding");
				res.writeVoidBody();
				return;
			}

			// enforce compatibility with HTTP/1.0 clients that do not support chunked encoding
			// (Squid and some other proxies)
			if (res.httpVersion == HTTPVersion.HTTP_1_0 && ("Transfer-Encoding" in cres.headers || "Content-Length" !in cres.headers)) {
				// copy all headers that may pass from upstream to client
				foreach (n, v; cres.headers) {
					if (n !in non_forward_headers_map)
						res.headers[n] = v;
				}

				if ("Transfer-Encoding" in res.headers) res.headers.remove("Transfer-Encoding");
				auto content = cres.bodyReader.readAll(1024*1024);
				res.headers["Content-Length"] = to!string(content.length);
				can_retry = false;
				if (res.isHeadResponse) res.writeVoidBody();
				else res.writeBody(content);
				return;
			}

			// to perform a verbatim copy of the client response
			if ("Content-Length" in cres.headers) {
				if ("Content-Encoding" in res.headers) res.headers.remove("Content-Encoding");
				foreach (key, value; cres.headers) {
					if (key !in non_forward_headers_map)
						res.headers[key] = value;
				}
				auto size = cres.headers["Content-Length"].to!size_t();
				logDebug("Request was: %s", req.requestURL);
				logDebug("Got headers =>");
				foreach (const key, const val; cres.headers) {
					logDebug("%s: %s", key, val);
				}
				can_retry = false;
				cres.readRawBody((scope reader) { res.writeRawBody(reader, size); });
				if (!res.headerWritten) res.writeVoidBody();
				res.finalize();
				return;
			}

			// fall back to a generic re-encoding of the response
			// copy all headers that may pass from upstream to client
			foreach (n, v; cres.headers) {
				if (n !in non_forward_headers_map) {
					if (settings.secure && settings.originSecure != settings.secure && icmp2("set-cookie", n) == 0) {
						v = v.replace("Secure; ", "");
					}
					res.headers[n] = v;
				}
			}

			can_retry = false;
			if (!cres.bodyReader.empty && !res.headerWritten)
				res.bodyWriter.write(cres.bodyReader);
			else if (!res.headerWritten)
				res.writeVoidBody();
		}
		//logTrace("Proxy requestHTTP");
		int failed;
		bool success;
		Exception ex;
		//do {
		try {
			if ("Upgrade" in req.headers && req.headers["Upgrade"] == "websocket") {
				static HTTPClientSettings ws_settings;
				if (!ws_settings || ws_settings.clonedFromAsPtrID != cast(size_t)&settings.clientSettings) {
					ws_settings = settings.clientSettings.clone();
					ws_settings.clonedFromAsPtrID = cast(size_t)&settings.clientSettings;
					ws_settings.defaultKeepAliveTimeout = 115.seconds;
					ws_settings.http2.alpn = ["http/1.1"];
					ws_settings.http2.disable = true;
				}
				handleWebSocket((scope ssock) {
					connectWebSocketEx(rurl, &setupClientRequest, (scope WebSocket csock) {
						// simple echo server
						Task ctask;
						Task stask;
						auto mtx = new InterruptibleTaskMutex();
						auto xchg_mtx = new InterruptibleTaskMutex();
						InterruptibleTaskCondition tcond = new InterruptibleTaskCondition(mtx);
						Exception w_ex;
						ctask = runTask({
							try {
								while(csock.connected && csock.waitForData()) {
									logDebug("csock got data, receiving");
									xchg_mtx.performLocked!({
										csock.receive((scope IncomingWebSocketMessage message) {
											logDebug("csock received message: %d", message.frameOpcode);
											switch (message.frameOpcode) {
												case FrameOpcode.binary:
													auto w_msg = message.readAll();
													logDebug("ssock.send: %s", w_msg);
													ssock.send( w_msg );
													logDebug("ssock sent.");
													break;
												case FrameOpcode.text:
													auto w_msg = message.readAllUTF8();
													logDebug("ssock.send: %s", w_msg);
													ssock.send( w_msg );
													logDebug("ssock sent.");
													break;
												case FrameOpcode.close:
													logDebug("ssock.close: %d: %s", csock.closeCode, csock.closeReason);
													ssock.close(csock.closeCode, csock.closeReason);
													stask.interrupt();
													if (tcond) tcond.notify();
													return;
												default:
													logDebug("ssock.receive: unknown opcode %s", message.frameOpcode);
													break;
											}

										});
									});
								}
							}
							catch (ConnectionClosedException e) {
								logDebug("csock was closed: %d: %s", csock.closeCode, csock.closeReason);
								if (csock.closeCode)
									ssock.close(csock.closeCode, csock.closeReason);
								else ssock.close(WebSocketCloseReason.normalClosure, "Normal closure");
								stask.interrupt();
								if (tcond) tcond.notify();
								return;
							}
							catch (InterruptException e) {
								return;
							}
							catch (Exception e) {
								w_ex = e;
								logDebug("ctask got exception: %s", e.toString());
							}
							catch (Throwable t) {
								w_ex = new Exception(t.toString());
								logDebug("ctask got assert error: %s", t.toString());
							}

							if (tcond) tcond.notify();
							stask.interrupt();

						});
						stask = runTask({
							try {
								while(ssock.connected && ssock.waitForData()) {
									logDebug("ssock got data, receiving");
									xchg_mtx.performLocked!({
										ssock.receive((scope IncomingWebSocketMessage message) {
											logDebug("ssock received message: %d", message.frameOpcode);
											switch (message.frameOpcode) {
												case FrameOpcode.binary:
													auto w_msg = message.readAll();
													logDebug("csock.send: %s", w_msg);
													csock.send( w_msg );
													logDebug("csock sent.");
													break;

												case FrameOpcode.text:
													auto w_msg = message.readAllUTF8();
													logDebug("csock.send: %s", w_msg);
													csock.send( w_msg );
													logDebug("csock sent.");
													break;
												case FrameOpcode.close:
													logDebug("csock.close: %d: %s", ssock.closeCode, ssock.closeReason);
													csock.close(ssock.closeCode, ssock.closeReason);
													ctask.interrupt();
													if (tcond) tcond.notify();
													return;
												default:
													logDebug("ssock.receive: unknown opcode %s", message.frameOpcode);
													break;
											}

										});
									});
								}
							}
							catch (ConnectionClosedException e) {
								logDebug("ssock was closed: %d: %s", ssock.closeCode, ssock.closeReason);
								if (ssock.closeCode)
									csock.close(ssock.closeCode, ssock.closeReason);
								else ssock.close(WebSocketCloseReason.normalClosure, "Normal closure");
								if (tcond) tcond.notify();
								return;
							}
							catch (InterruptException e) {
								return;
							}
							catch (Exception e) {
								w_ex = e;
								logDebug("stask got exception: %s", e.toString());
							}
							catch (Throwable t) {
								w_ex = new Exception(t.toString());
								logDebug("stask got assert error: %s", t.toString());
							}
							if (tcond) tcond.notifyAll();
							ctask.interrupt();
						});
						mtx.performLocked!({
							tcond.wait();
						});
						tcond = null;
						if (w_ex) {
							logDebug("Closing websocket connection due to exception: %s", ex.toString());
						}

					}, ws_settings);
				}, req, res);
				return;
			}
			else requestHTTP(rurl, &setupClientRequest, &handleClientResponse, settings.clientSettings);
			success = true;
		}
		catch (Exception e) {
			//if (!can_retry) throw e;
			//else {
			ex = e;
			//}
		}

		//} while(!success && ++failed < 3);
		if (!success) {
			throw ex;
		}
	}

	return &handleRequest;
}
/// ditto
HTTPServerRequestDelegateS reverseProxyRequest(string destination_host, ushort destination_port)
{
	auto settings = new HTTPReverseProxySettings;
	settings.destinationHost = destination_host;
	settings.destinationPort = destination_port;
	return reverseProxyRequest(settings);
}

/**
	Provides advanced configuration facilities for reverse proxy servers.
*/
final class HTTPReverseProxySettings {
	string destinationIP;
	/// The destination host to forward requests to
	string destinationHost;
	/// The destination port to forward requests to
	ushort destinationPort;
	/// Avoids compressed transfers between proxy and destination hosts
	bool avoidCompressedRequests;
	bool secure;
	bool originSecure;
	bool anonymous;
	InetHeaderMap defaultHeaders;
	InetHeaderMap defaultResponseHeaders;
	HTTPClientSettings clientSettings;
}
