module vibe.http.debugger;

version(VibeNoDebug) {} else:

import vibe.core.core : getAvailableFiberCount;
import vibe.core.log : logError;
import vibe.core.task;
import vibe.http.router : HTTPServerRequestDelegateS, URLRouter;
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

void printSummary(scope HTTPServerResponse res)
{

	res.bodyWriter.write(format("Have %d HTTP/2 sessions running\n\n", HTTP2Session.totalSessions));
	res.bodyWriter.write(format("Have %d HTTP/2 streams running\n\n", HTTP2Stream.totalStreams));
	res.bodyWriter.write(format("Have %d bytes of data in manualAllocator()\n\n", (cast(DebugAllocator)manualAllocator()).bytesAllocated()));
	res.bodyWriter.write(format("Have %d bytes of data in AppMem\n\n", getAllocator!NativeGC().bytesAllocated()));
	res.bodyWriter.write(format("Have %d bytes of data in ThreadMem\n\n", getAllocator!Lockless().bytesAllocated()));
	res.bodyWriter.write(format("Have %d bytes of data in SecureMem\n\n", getAllocator!CryptoSafe().bytesAllocated()));

}

void printTaskInfo(scope HTTPServerResponse res, Task t = Task.getThis()) {
	res.bodyWriter.write(format("\nTask %s (%d B) [%s] [", cast(void*)t.fiber, TaskDebugger.getMemoryUsage(t), TaskDebugger.getTaskName(t)));
	
	auto bcrumbs = TaskDebugger.getBreadcrumbs(t);
	int i;
	foreach (bcrumb; bcrumbs[]) {
		res.bodyWriter.write(bcrumb);
		if (++i != bcrumbs.length)
			res.bodyWriter.write(" > ");
	}
	res.bodyWriter.write("]");
}

HTTPServerRequestDelegateS serveAllocations() {

	void allocations(scope HTTPServerRequest req, scope HTTPServerResponse res) {
		res.contentType = "text/plain";
		res.printSummary();
		res.bodyWriter.write("\nVibe manual allocations: \n\n");
		foreach (const ref size_t sz; (cast(DebugAllocator)manualAllocator()).blocks) {
			res.bodyWriter.write(format("Entry sz %d\n", sz));
		}

		version(DictionaryDebugger) {
			auto map = getAllocator!NativeGC().getMap();
			auto map1 = getAllocator!Lockless().getMap();
			auto map2 = getAllocator!CryptoSafe().getMap();
			res.bodyWriter.write("\nAppMem allocations: \n");
			foreach (const ref size_t ptr, const ref size_t sz; map) 
				res.bodyWriter.write(format("Entry %s => %d\n", cast(void*)ptr, sz));

			res.bodyWriter.write("\nThreadMem allocations: \n");
			foreach (const ref size_t ptr, const ref size_t sz; map1) 
				res.bodyWriter.write(format("Entry %s => %d\n", cast(void*)ptr, sz));

			res.bodyWriter.write("\nSecureMem allocations: \n");
			foreach (const ref size_t ptr, const ref size_t sz; map2) 
				res.bodyWriter.write(format("Entry %s => %d\n", cast(void*)ptr, sz));
		} else {
			res.bodyWriter.write("Vibe must be built with version 'DictionaryDebugger' in order to print a list of allocations. This
tag is disabled by default because it slows down a server significantly.");
		}
	}
	return &allocations;

}


HTTPServerRequestDelegateS serveTaskManager() {
	void taskManager(scope HTTPServerRequest req, scope HTTPServerResponse res) {
		res.contentType = "text/plain";
		res.printSummary();

		version(VibeLibasyncDriver) {
			import vibe.core.drivers.libasync;
			res.bodyWriter.write(format("Have %d TCP connections active\n\n", LibasyncTCPConnection.totalConnections));
		}
		auto tasks = TaskDebugger.getActiveTasks();
		res.bodyWriter.write(format("Have %d Active and %d Pending fibers\n\n", tasks.length, getAvailableFiberCount()));
		res.bodyWriter.write("Active fibers:\n");
		foreach (Task t; tasks)
		{
			res.printTaskInfo(t);

			// inactivity details:
			res.bodyWriter.write(format(" [Age: %s] [Inactivity: %s]\n\n", TaskDebugger.getAge(t).toString(), TaskDebugger.getInactivity(t).toString()));

			res.bodyWriter.write(format("\tCall Stack:\n"));
			auto cs = TaskDebugger.getCallStack(t);
			foreach_reverse (string info; cs[])
				res.bodyWriter.write(format("\t\t%s\n", info));
		}
	}
	return &taskManager;
}

/// must supply parameters: name, breadcrumbs, keywords
HTTPServerRequestDelegateS serveCapture() {
	void capture(scope HTTPServerRequest req, scope HTTPServerResponse res) {
		import std.array : array;
		import std.algorithm : splitter;
		import vibe.core.driver;
		auto ev = getEventDriver().createManualEvent();
		bool finished;

		CaptureFilters filters;
		filters.name = req.params.get("name", "");
		filters.breadcrumbs = req.params.get("breadcrumbs", "").splitter(",").array;
		filters.keywords = req.params.get("keywords", "").splitter(",").array;

		if (filters.name == "" || filters.breadcrumbs.length == 0 || filters.keywords.length == 0)
			return;

		filters.maxTasks = 1;
		CaptureSettings settings = new CaptureSettings;
		settings.filters = filters;

		bool task_info_printed;

		settings.sink = (string keyword, lazy string str) nothrow {
			try {
				if (!task_info_printed) {
					res.printTaskInfo();
					task_info_printed = true;
				}
				res.bodyWriter.write(format("[%s] %s\n", keyword, str));
			}
			catch (Exception e) {
				try logError("%s", e.toString()); catch {}
			}
		};
		settings.finalize = () nothrow { 
			finished = true; 
			try ev.emitLocal(); 
			catch (Exception e) { try logError("%s", e.toString()); catch {} }
		};

		TaskDebugger.startCapturing(settings);
		while(!finished) ev.waitLocal();
	}

	return &capture;
}

HTTPServerRequestDelegateS serveCaptureForm() {
	void captureForm(scope HTTPServerRequest req, scope HTTPServerResponse res) 
	{
		res.contentType = "text/html";
		res.writeBody(import("capture.html"));
	}


	return &captureForm;
}

void setupDebugger(URLRouter router) nothrow {
	try {
		if (router.prefix.length > 0) return;
		router.get("/allocations/", serveAllocations());
		router.get("/task_manager/", serveTaskManager());
		router.get("/do_capture/", serveCapture());
		router.get("/capture/", serveCaptureForm());
	} catch (Exception e) { try logError("%s", e.toString()); catch {} }
}

static this() {
	URLRouter.addCtor(&setupDebugger);
}