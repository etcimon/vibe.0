module vibe.http.debugger;

version(EnableDebugger):
version(VibeFiberDebug):
version(VibeLibasyncDriver):

import vibe.core.drivers.libasync;
import vibe.core.core : getAvailableFiberCount;
import vibe.core.task;
import vibe.http.router : HTTPServerRequestDelegateS;
import vibe.http.server;
import vibe.http.http2 : HTTP2Stream, HTTP2Session;
import vibe.utils.memory : DebugAllocator, manualAllocator;
import vibe.core.trace;
import memutils.allocators;

import std.string : format;

// todo: Add type info to allocations
// todo: Add DebugInfo to fibers accross the vibe framework

enum NativeGC = 0x01;
enum Lockless = 0x02;
enum CryptoSafe = 0x03;
HTTPServerRequestDelegateS serveDebugger() {
	void webDebug(scope HTTPServerRequest req, scope HTTPServerResponse res) {
		import vibe.data.json : serializeToPrettyJson;
		res.contentType = "text/plain";
		res.bodyWriter.write(std.string.format("Have %d TCP connections active\n\n", LibasyncTCPConnection.totalConnections));
		res.bodyWriter.write(std.string.format("Have %d HTTP/2 sessions running\n\n", HTTP2Session.totalSessions));
		res.bodyWriter.write(std.string.format("Have %d HTTP/2 streams running\n\n", HTTP2Stream.totalStreams));
		res.bodyWriter.write(std.string.format("Have %d bytes of data in manualAllocator()\n\n", (cast(DebugAllocator)manualAllocator()).bytesAllocated()));
		res.bodyWriter.write(std.string.format("Have %d bytes of data in AppMem\n\n", getAllocator!NativeGC().bytesAllocated()));
		res.bodyWriter.write(std.string.format("Have %d bytes of data in ThreadMem\n\n", getAllocator!Lockless().bytesAllocated()));
		res.bodyWriter.write(std.string.format("Have %d bytes of data in SecureMem\n\n", getAllocator!CryptoSafe().bytesAllocated()));

		auto tasks = TaskDebugger.getActiveTasks();
		res.bodyWriter.write(std.string.format("Have %d Active and %d Pending fibers\n\n", tasks.length, getAvailableFiberCount()));
		res.bodyWriter.write("Active fibers:\n");
		foreach (Task t; tasks)
		{
			res.bodyWriter.write(std.string.format("\nTask %s (%d B) [%s] [", cast(void*)t.fiber, TaskDebugger.getMemoryUsage(t), TaskDebugger.getTaskName(t)));

			auto bcrumbs = TaskDebugger.getBreadcrumbs(t);
			int i;
			foreach (bcrumb; bcrumbs[]) {
				res.bodyWriter.write(bcrumb);
				if (++i != bcrumbs.length)
					res.bodyWriter.write(" > ");
			}
			res.bodyWriter.write(std.string.format("] [Age: %s] [Inactivity: %s]\n\n", TaskDebugger.getAge(t).toString(), TaskDebugger.getInactivity(t).toString()));

			res.bodyWriter.write(std.string.format("\tCall Stack:\n"));
			auto cs = TaskDebugger.getCallStack(t);
			foreach_reverse (string info; cs[])
				res.bodyWriter.write(std.string.format("\t\t%s\n", info));
		}
		/*
		res.bodyWriter.write("\nVibe manual allocations: \n\n");
		foreach (const ref size_t sz; (cast(DebugAllocator)manualAllocator()).blocks) {
			res.bodyWriter.write(std.string.format("Entry sz %d\n", sz));
		}
		
		auto map = getAllocator!NativeGC().getMap();
		auto map1 = getAllocator!Lockless().getMap();
		auto map2 = getAllocator!CryptoSafe().getMap();
		res.bodyWriter.write("\nAppMem allocations: \n");
		foreach (const ref size_t ptr, const ref size_t sz; map) 
			res.bodyWriter.write(std.string.format("Entry %s => %d\n", cast(void*)ptr, sz));

		res.bodyWriter.write("\nThreadMem allocations: \n");
		foreach (const ref size_t ptr, const ref size_t sz; map1) 
			res.bodyWriter.write(std.string.format("Entry %s => %d\n", cast(void*)ptr, sz));

		res.bodyWriter.write("\nSecureMem allocations: \n");
		foreach (const ref size_t ptr, const ref size_t sz; map2) 
			res.bodyWriter.write(std.string.format("Entry %s => %d\n", cast(void*)ptr, sz));
		*/

	}
	return &webDebug;
}