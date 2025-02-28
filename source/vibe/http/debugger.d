﻿module vibe.http.debugger;

version(VibeNoDebug) {} else:

import vibe.core.core : getAvailableFiberCount;
import vibe.core.log : logError;
import vibe.core.task;
import vibe.http.router : HTTPServerRequestDelegateS, URLRouter;
import vibe.http.server;
import vibe.http.http2 : HTTP2Stream, HTTP2Session;
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

		import vibe.core.drivers.libasync;
		res.bodyWriter.write(format("Have %d TCP connections active\n\n", LibasyncTCPConnection.totalConnections));

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
	void do_capture(scope HTTPServerRequest req, scope HTTPServerResponse res) {
		import vibe.core.core;

		mixin(Trace);
		res.silent();

		import std.array : array;
		import std.algorithm : splitter;
		import vibe.core.driver;
		auto ev = getEventDriver().createManualEvent();
		bool finished;

		CaptureFilters filters;
		filters.name = req.form.get("name", "");
		filters.breadcrumbs = req.form.get("breadcrumbs", "").splitter(",").array;
		filters.keywords = req.form.get("keywords", "").splitter(",").array;

		if (filters.name == "" || filters.breadcrumbs.length == 0 || filters.keywords.length == 0)
			return;
		

		filters.maxTasks = 1;
		CaptureSettings settings = new CaptureSettings;
		settings.filters = filters;

		bool task_info_printed;

		import std.stdio : writeln;
		settings.sink = (string keyword, lazy string str) nothrow {
			try {
				if (!task_info_printed) {
					res.printTaskInfo();
					task_info_printed = true;
				}
				res.bodyWriter.write(format("\n[%s]\n%s\n", keyword, str));
			}
			catch (Exception e) {
				try logError("%s", e.toString()); catch(Throwable e) {}
			}
		};
		settings.finalize = () nothrow { 
			finished = true; 
			try {
				ev.emit(); 
			}
			catch (Exception e) { try logError("%s", e.toString()); catch(Throwable e) {} }
		};

		TaskDebugger.startCapturing(settings);
		import std.datetime : seconds;
		if ("content-encoding" in res.headers) res.headers.remove("Content-Encoding");
		ev.wait(30.seconds, ev.emitCount);
	}

	return &do_capture;
}

HTTPServerRequestDelegateS serveCaptureForm() {
	void captureForm(scope HTTPServerRequest req, scope HTTPServerResponse res) 
	{
		res.writeBody(import("capture.html"), "text/html");
	}


	return &captureForm;
}

void setupDebugger(URLRouter router) nothrow {
	try {
		router.get("/debugger/", serveCaptureForm());
		router.get("/debugger/allocations/", serveAllocations());
		router.get("/debugger/task_manager/", serveTaskManager());
		router.post("/debugger/capture/", serveCapture());
	} catch (Exception e) { try logError("%s", e.toString()); catch(Throwable e) {} }
}