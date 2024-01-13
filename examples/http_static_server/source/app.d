import vibe.appmain;
import vibe.http.fileserver;
import vibe.http.router;
import vibe.http.server;
import vibe.core.core;
void handleRequest(scope HTTPServerRequest req, scope HTTPServerResponse res)
{
	res.writeBody("<html>
<head>
	<title>Hello, World!</title>
</head>
<body>
	<h1>It works!</h1>
	<p>You have successfully installed the minimal static HTTP server!</p>
</body>
</html>
", 200);
}

void main()
{
	auto settings = new HTTPServerSettings;
	settings.port = 8080;
	settings.bindAddresses = ["::1", "127.0.0.1"];

	auto router = new URLRouter;
	router.get("/", &handleRequest);
	auto fileServerSettings = new HTTPFileServerSettings;
	fileServerSettings.encodingFileExtension = ["gzip" : ".gz"];
	router.get("/gzip/*", serveStaticFiles("./public/", fileServerSettings));
	router.get("*", serveStaticFiles("./public/",));

	listenHTTP(settings, router);
	runEventLoop();
}
