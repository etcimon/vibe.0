module vibe.core.trace;

import std.stdio;
/// Appends provided string for a breadcrumbs-style naming of the active Task
string Name(string name)() {
	version(VibeNoDebug) {
		return "";
	} else
		return "TaskDebugger.setTaskName(`" ~ name ~ "`);";
}

string Breadcrumb(alias bcrumb)() {
	version(VibeNoDebug) {
		return "";
	} else {
		static if (__traits(identifier, bcrumb) != "bcrumb")
			return "TaskDebugger.addBreadcrumb(" ~ __traits(identifier, bcrumb) ~ ");";
		else return "TaskDebugger.addBreadcrumb(`" ~ bcrumb ~ "`);";
	}
}

version(VibeNoDebug) {} else:

public import memutils.vector;
public import vibe.core.task;

// Trace is provided by vibe.core.core
public import vibe.core.core : Trace;
import memutils.hashmap;
import memutils.rbtree;
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
	Vector!string getCallStack(Task t = Task.getThis(), bool in_catch = true) {
		scope(failure) assert(false);
		try if (auto ptr = t.fiber in s_taskMap) {
			auto ret = ptr.callStack.dup;
			if (in_catch && ptr.failures > 0) {
				foreach (i; 0 .. ptr.failures)
					ptr.callStack.removeBack();
			}
			return ret.move;
		} catch (Exception e) { try writeln("Couldn't get call stack"); catch {} }
		return Vector!string(["No call stack"]);
	}

	void setTaskName(string name) {
		setTaskName(Task.getThis(), name);
	}

	void setTaskName(Task t, string name) {
		scope(failure) assert(false);
		if (auto ptr = t.fiber in s_taskMap) {
			ptr.name = name;

			if (isCapturing) {
				foreach (settings; s_captureSettings[]) {
					if (settings.canCapture(*ptr))
					{
						settings.attachTask(*ptr);

					}
				}
			}
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
		if (auto ptr = Task.getThis().fiber in s_taskMap) {
			ptr.breadcrumbs ~= bcrumb;
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
		static ulong id;
		// adds a filter to which one or more tasks will be attached according to predicates
		// the handler will be called for each `onCapture` event.
		settings.remainingTasks = settings.filters.maxTasks;
		setIsCapturing(true);
		// todo: add capture to existing tasks if option is set
		settings.id = id++;
		try s_captureSettings.insert(settings); 
		catch (Exception e) { setIsCapturing(false); return 0; }
		return settings.id;
	}

	/// Stops capturing the specified handler ID
	void stopCapturing(ulong id) {
		try {
			CaptureSettings cmp = ThreadMem.alloc!CaptureSettings();
			scope(exit) ThreadMem.free(cmp);

			auto settings = s_captureSettings.getValuesAt(cmp);
			import std.range : front;
			settings.front.detachAll();
		} catch (Exception e) { try writeln(e.toString()); catch {} }
		// removes the filter, detaches all attached tasks
	}
}

class CaptureSettings {
	// The configuration to be respected during the capture
	CaptureFilters filters;
	// The delegate which will receive capture data
	void delegate(string, lazy string) nothrow sink;
	// Called when the capture is finished
	void delegate() nothrow finalize;

	int opCmp(CaptureSettings other) const {
		if (other.id == this.id) return 0;
		if (other.id < this.id) return -1;
		else return 1;
	}
private:
	// the unique ID for this capture
	ulong id;
	// All attached tasks will appear here
	Vector!TaskDebugInfo tasks;
	// The amount of tasks remaining before the capture is forcibly finalized
	uint remainingTasks = uint.max;

	bool canCapture(TaskDebugInfo t) {
		if (remainingTasks == 0) return false;
		import std.algorithm : canFind;
		// name must be an exact match
		if (!globMatch(filters.name, t.name)) 
			return false;

		// all of the filter breadcrumbs must be contained
		if (filters.breadcrumbs != ["*"] ) {
			foreach (glob; filters.breadcrumbs) {
				foreach (breadcrumb; t.breadcrumbs[])
					if (!globMatch(glob, breadcrumb))
						return false;
			}
		}
		return true;
	}

	bool attachTask(TaskDebugInfo t) {
		if (remainingTasks == 0)
			return false;
		tasks ~= t;
		t.captures ~= this;
		remainingTasks--;
		return true;
	}

	void detachTask(TaskDebugInfo t) {
		removeFromArray(tasks, t);
		checkFinished();
	}

	void detachTask(Task t) {
		if (t == Task()) return;
		if (auto ptr = t.fiber in s_taskMap) {
			detachTask(*ptr);
		}
	}

	void detachAll() {
		foreach (TaskDebugInfo tdi; tasks[]) {
			removeFromArray(tdi.captures, this);
		}
		checkFinished();
	}

	private void checkFinished() {
		if (remainingTasks == 0) {
			finalize();
			s_captureSettings.remove(this);
			if (s_captureSettings.empty)
				setIsCapturing(false);
		}
	}
}	

struct CaptureFilters {
	/// The name of the task. Use * ? globbing wildcards
	string name;
	/// The capture events requested. Use * ? globbing wildcards
	string[] keywords;
	/// The breadcrumbs which must be contained within the monitored Task's breadcrumbs. Use * ? globbing wildcards
	string[] breadcrumbs;
	/// The maximum number of tasks that can be monitored, after which the capture is automatically stopped
	uint maxTasks = uint.max;
	/// Whether existing tasks should be scanned. If not, tasks will join the capture 
	/// the moment they match those filters (when adding breadcrumbs, changing names, etc).
	// todo: bool scanExistingTasks;
}

private:

class TaskDebugInfo {
	Task task;
	string name;
	Vector!string breadcrumbs;
	Vector!string callStack;
	uint failures; // used to unwind the call stack
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
				foreach (capture; ptr.captures)
					capture.detachTask(*ptr);
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

void removeFromArray(T)(ref Vector!T arr, ref T t) {
	// remove from the list
	size_t idx;
	foreach (i, val; arr[]) {
		if (val is t) {
			idx = i;
			break;
		}
	}

	Vector!T tmp = Vector!T(arr[0 .. idx]);
	if (arr.length - 1 > idx)
		tmp ~= arr[idx .. $];
	arr.swap(tmp);

}

void pushTraceImpl(string info) {
	if (Task.getThis() == Task()) return;
	if (auto ptr = Task.getThis().fiber in s_taskMap) {
		ptr.callStack ~= info;
	}
	
}

void popTraceImpl(bool in_failure = false) {
	if (Task.getThis() == Task()) return;
	if (auto ptr = Task.getThis().fiber in s_taskMap) {
		if (in_failure) ptr.failures++;
		else ptr.callStack.removeBack();
	}
}

void onCapturedImpl(string keyword, lazy string data) {
	if (Task.getThis() == Task()) return;
	if (auto t = Task.getThis().fiber in s_taskMap) {
		if (t.captures.length > 0)
		{
			foreach (CaptureSettings capture; t.captures[]) {
				foreach (glob; capture.filters.keywords)
					if (globMatch(glob, keyword))
						capture.sink(keyword, data);
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
RBTree!(CaptureSettings, "a < b", false, Malloc) s_captureSettings;

static this() {
	import core.thread;
	import memutils.allocators;
	setTaskEventCallback(&taskEventCallback);
	setPushTrace(&pushTraceImpl);
	setPopTrace(&popTraceImpl);
	setCapturesCallback(&onCapturedImpl);
	enum NativeGC = 0x01;
	enum Lockless = 0x02;
	enum CryptoSafe = 0x03;
	getAllocator!NativeGC().setAllocSizeCallbacks(&onAlloc, &onFree);
	getAllocator!Lockless().setAllocSizeCallbacks(&onAlloc, &onFree);
	getAllocator!CryptoSafe().setAllocSizeCallbacks(&onAlloc, &onFree);

}

bool globMatch(string pattern, string str)
{
	immutable(char)* a_pos = pattern.ptr;
	immutable(char)* b_pos = str.ptr;
	immutable(char)* a_end = pattern.ptr + pattern.length;
	immutable(char)* b_end = str.ptr + str.length;

	immutable(char) downcase(immutable(char) c) {
		return cast(char)('A' <= c && c <= 'Z' ? (c - 'A' + 'a') : c);
	}

	while (a_pos !is a_end && b_pos !is b_end) {		
		if (*a_pos == '*') {
			while (a_pos !is a_end && *a_pos == '*')
				a_pos++;
			
			if(a_pos is a_end)
				return true;
			do {
				b_pos++;
				if (bool is_match = globMatch(a_pos[0 .. a_end-a_pos], b_pos[0 .. b_end-b_pos]))
					return true;
			}
			while (b_pos !is b_end && downcase(*b_pos) != downcase(*a_pos));
		} else if (*a_pos == '?' || downcase(*a_pos) == downcase(*b_pos))
		{
			a_pos++;
			b_pos++;
		}
		else
			break;
	}
	
	if(a_pos is a_end && b_pos is b_end)
		return true;
	return false;
}