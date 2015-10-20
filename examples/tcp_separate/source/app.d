import vibe.appmain;
import vibe.core.core : runTask, sleep;
import vibe.core.log : logInfo;
import vibe.core.net : listenTCP;
import vibe.stream.operations : readLine;

import core.time;
import vibe.d;

shared static this()
{
    runTask({
        listenTCP(8080, (TCPConnection conn) {
            auto data = new ubyte[1024 * 128];
            conn.write(data);
            conn.finalize();
            conn.close();
        }, "127.0.0.1");
    });
    runTask({
        auto conn = connectTCP("127.0.0.1", 8080);
        auto data = conn.readAll;
        logInfo("length: %s", data.length);
        conn.close();
    });
}