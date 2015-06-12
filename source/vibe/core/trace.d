module vibe.core.trace;

import std.stdio;
/// Appends provided string for a breadcrumbs-style naming of the active Task
string Name(string name)() {
	version(VibeFiberDebug)
		return "TaskDebugger.setTaskName(`" ~ name ~ "`);";
	else return "";
}

string Breadcrumb(alias bcrumb)() {
	version(VibeFiberDebug) {
		static if (__traits(identifier, bcrumb) != "bcrumb")
			return "TaskDebugger.addBreadcrumb(" ~ __traits(identifier, bcrumb) ~ ");";
		else return "TaskDebugger.addBreadcrumb(`" ~ bcrumb ~ "`);";
	}
	else return "";
}

version(VibeFiberDebug):

public import memutils.vector;
public import vibe.core.task;

// Trace is provided by vibe.core.core
public import vibe.core.core : Trace, StackTrace;
import memutils.hashmap;
import memutils.utils;
import std.datetime;
import vibe.core.core;

struct TaskDebugger {
nothrow static:
	// Returns all tasks currently started
	Task[] getActiveTasks() {
		scope(failure) assert(false);
		import std.array : Appender;
		Appender!(Task[]) keys;

		foreach (const ref TaskFiber t, const ref TaskDebugInfo tdi; s_taskMap) 
			keys ~= (cast()t).task;
		
		return keys.data;
	}

	// Fetches the call stack of a currently yielded task
	Vector!string getCallStack(Task t = Task.getThis()) {
		scope(failure) assert(false);
		if (auto ptr = t.fiber in s_taskMap) {
			return ptr.callStack.dup;
		}
		return Vector!string(["No call stack"]);
	}

	void setTaskName(string name) {
		scope(failure) assert(false);
		if (auto tls_tdi = Task.getThis().fiber in s_taskMap) {
			tls_tdi.name = name;
		}
	}

	void setTaskName(Task t, string name) {
		scope(failure) assert(false);
		if (auto ptr = t.fiber in s_taskMap) {
			ptr.name = name;
		}
	}

	string getTaskName(Task t = Task.getThis()) {
		scope(failure) assert(false);
		if (auto ptr = t.fiber in s_taskMap) {
			return ptr.name;
		}
		return "Invalid Task";
	}

	void addBreadcrumb(string bcrumb) {
		scope(failure) assert(false);
		if (auto tls_tdi = Task.getThis().fiber in s_taskMap) {
			tls_tdi.breadcrumbs ~= bcrumb;
		}
	}

	void addBreadcrumb(Task t, string bcrumb) {
		scope(failure) assert(false);
		if (auto ptr = t.fiber in s_taskMap) {
			ptr.breadcrumbs ~= bcrumb;
		}
	}

	string[] getBreadcrumbs(Task t = Task.getThis()) {
		scope(failure) assert(false);
		if (auto ptr = t.fiber in s_taskMap) {
			return ptr.breadcrumbs[].dup;
		}
		return ["Invalid Task"];
	}

	Duration getAge(Task t = Task.getThis()) {
		scope(failure) assert(false);
		
		if (auto ptr = t.fiber in s_taskMap) {
			return Clock.currTime() - ptr.created;
		}
		return 0.seconds;
	}

	Duration getInactivity(Task t = Task.getThis()) {
		scope(failure) assert(false);
		
		if (auto ptr = t.fiber in s_taskMap) {
			return Clock.currTime() - ptr.lastResumed;
		}
		return 0.seconds;
	}

	size_t getMemoryUsage(Task t = Task.getThis()) {
		scope(failure) assert(false);
		
		if (auto ptr = t.fiber in s_taskMap) {
			return ptr.memoryUsage;
		}
		return 0;
	}

	/// Starts capturing data using the specified handler. Returns the capture ID
	ulong startCapturing(CaptureSettings settings) {
		// adds a filter to which one or more tasks will be attached according to predicates
		// the handler will be called for each `onCapture` event.
		settings.remainingTasks = settings.filters.maxTasks;
	}

	/// Stops capturing the specified handler ID
	void stopCapturing(ulong id) {
		// removes the filter, detaches all attached tasks
	}
}

class CaptureSettings {
	// The configuration to be respected during the capture
	CaptureFilters filters;
	// The delegate which will receive capture data
	void delegate(lazy string) sink nothrow;
	// Called when the capture is finished
	void delegate() finalize nothrow;

private:
	// the unique ID for this capture
	ulong id;
	// All attached tasks will appear here
	Vector!TaskDebugInfo tasks;
	// To respect the total limits
	int remainingTasks = size_t.max;

	bool attachTask(TaskDebugInfo t) {
		if (remainingTasks == 0)
			return false;
		tasks ~= t;
		remainingTasks--;
		return true;
	}

	void detachTask(Task t) {

	}
}	

struct CaptureFilters {
	/// The name of the task. Use "*" for a wildcard
	string name;
	/// The capture events requested. Use ["*"] for a wildcard
	string[] keywords;
	/// The breadcrumbs which must be contained within the monitored Task's breadcrumbs. Use ["*"] for a wildcard
	string[] breadcrumbs;
	/// The maximum number of tasks that can be monitored, after which the capture is automatically stopped
	int maxTasks = size_t.max;
	/// Whether existing tasks should be scanned. If not, tasks will join the capture 
	/// the moment they match those filters (when adding breadcrumbs, changing names, etc).
	bool scanExistingTasks;
}

private:

class TaskDebugInfo {
	Task task;
	string name;
	Vector!string breadcrumbs;
	Vector!string callStack;
	Vector!CaptureSettings captures;
	SysTime created;
	SysTime lastResumed;
	size_t memoryUsage;
}

void taskEventCallback(TaskEvent ev, Task t) nothrow {
	try {
		if (ev == TaskEvent.end || ev == TaskEvent.fail)
		{
			if (auto ptr = t.fiber in s_taskMap)
			{
				// detach from capture settings
				ThreadMem.free(*ptr);
				s_taskMap.remove(t.fiber);
			}
		}
		else if (ev == TaskEvent.start) {
			TaskDebugInfo tdi = ThreadMem.alloc!TaskDebugInfo();
			tdi.task = t;
			tdi.name = "Core";
			tdi.created = Clock.currTime();
			tdi.lastResumed = Clock.currTime();
			s_taskMap[t.fiber] = tdi;
		}
		else if (ev == TaskEvent.resume) {
			if (auto ptr = t.fiber in s_taskMap)
			{
				ptr.lastResumed = Clock.currTime();
			}
		}
	} catch (Throwable e) {
		try writeln(e.toString()); catch {}
	}
}


void pushTrace(string info) {
	if (Task.getThis() == Task()) return;
	if (auto tls_tdi = Task.getThis().fiber in s_taskMap) {
		tls_tdi.callStack ~= info;
	}
	
}

void popTrace() {
	if (Task.getThis() == Task()) return;
	if (auto tls_tdi = Task.getThis().fiber in s_taskMap) {
		tls_tdi.callStack.removeBack();
	}
}


void onCaptured(lazy string data) {
	scope(failure) assert(false);
	if (Task.getThis() == Task()) return;
	if (auto t = Task.getThis().fiber in s_taskMap) {
		if (t.captures.length > 0)
		{
			foreach (CaptureSettings capture; t.captures[]) {
				capture.sink(data);
			}
		}
	}
}
void onFree(size_t sz) {
	if (Task.getThis() == Task()) return;
	if (auto t = Task.getThis().fiber in s_taskMap) {
		if (t.memoryUsage > sz)
			t.memoryUsage -= sz;
		else t.memoryUsage = 0;
	}
}

void onAlloc(size_t sz) {
	if (Task.getThis() == Task()) return;
	if (auto t = Task.getThis().fiber in s_taskMap) {
		t.memoryUsage += sz;
	}
}

HashMap!(TaskFiber, TaskDebugInfo, Malloc) s_taskMap;
RBTree!(CaptureSettings, "a.id < b.id", Malloc) s_captureSettings;

static this() {
	import core.thread;
	import memutils.allocators;
	setTaskEventCallback(&taskEventCallback);
	setPushTrace(&pushTrace);
	setPopTrace(&popTrace);
	setCapturesCallback(&TaskDebugger.onCaptured);
	enum NativeGC = 0x01;
	enum Lockless = 0x02;
	enum CryptoSafe = 0x03;
	getAllocator!NativeGC().setAllocSizeCallbacks(&onAlloc, &onFree);
	getAllocator!Lockless().setAllocSizeCallbacks(&onAlloc, &onFree);
	getAllocator!CryptoSafe().setAllocSizeCallbacks(&onAlloc, &onFree);

}