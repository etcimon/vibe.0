import vibe.http.fileserver;
import vibe.http.router : URLRouter;
import vibe.http.server;
import vibe.core.log;

__gshared ubyte[] globalBuffer;

void getIndex(scope HTTPServerRequest request, scope HTTPServerResponse response) {
  response.render!("index.dt", request);
}

void getImage(scope HTTPServerRequest request, scope HTTPServerResponse response) {
  response.contentType = "image/jpeg";
  response.writeBody(globalBuffer);
  
}

shared static this() {
  globalBuffer = cast(ubyte[])std.file.read("test.jpg");

  auto router = new URLRouter;
  router.get("/", &getIndex);
  router.get("/image", &getImage);
  router.get("*", serveStaticFiles("./public/"));

  auto settings = new HTTPServerSettings;
  settings.port = 8080;
  listenHTTP(settings, router);
}