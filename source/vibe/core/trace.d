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

		foreach (const ref TaskID t, const ref TaskDebugInfo tdi; s_taskMap) 
			keys ~= Task(cast(TaskFiber)cast(void*)t[0], t[1]);
		
		return keys.data;
	}

	// Fetches the call stack of a currently yielded task
	Vector!string getCallStack(Task t = Task.getThis()) {
		scope(failure) assert(false);
		if (auto ptr = t.id in s_taskMap) {
			return ptr.callStack.dup;
		}
		return Vector!string(["No call stack"]);
	}

	void setTaskName(string name) {
		scope(failure) assert(false);
		if (auto tls_tdi = Task.getThis().id in s_taskMap) {
			tls_tdi.name = name;
		}
	}

	void setTaskName(Task t, string name) {
		scope(failure) assert(false);
		if (auto ptr = t.id in s_taskMap) {
			ptr.name = name;
		}
	}

	string getTaskName(Task t = Task.getThis()) {
		scope(failure) assert(false);
		if (auto ptr = t.id in s_taskMap) {
			return ptr.name;
		}
		return "Invalid Task";
	}

	void addBreadcrumb(string bcrumb) {
		scope(failure) assert(false);
		if (auto tls_tdi = Task.getThis().id in s_taskMap) {
			tls_tdi.breadcrumbs ~= bcrumb;
		}
	}

	void addBreadcrumb(Task t, string bcrumb) {
		scope(failure) assert(false);
		if (auto ptr = t.id in s_taskMap) {
			ptr.breadcrumbs ~= bcrumb;
		}
	}

	string[] getBreadcrumbs(Task t = Task.getThis()) {
		scope(failure) assert(false);
		if (auto ptr = t.id in s_taskMap) {
			return ptr.breadcrumbs[].dup;
		}
		return ["Invalid Task"];
	}

	Duration getAge(Task t = Task.getThis()) {
		scope(failure) assert(false);
		
		if (auto ptr = t.id in s_taskMap) {
			return Clock.currTime() - ptr.created;
		}
		return 0.seconds;
	}

	Duration getInactivity(Task t = Task.getThis()) {
		scope(failure) assert(false);
		
		if (auto ptr = t.id in s_taskMap) {
			return Clock.currTime() - ptr.lastResumed;
		}
		return 0.seconds;
	}
}

private:

bool init() {
	if (Task.getThis() == Task()) return false;
	return true;
}

void pushTrace(string info) {
	if (Task.getThis() == Task()) return;
	if (auto tls_tdi = Task.getThis().id in s_taskMap) {
		tls_tdi.callStack ~= info;
	}

}

void popTrace() {
	if (Task.getThis() == Task()) return;
	if (auto tls_tdi = Task.getThis().id in s_taskMap) {
		tls_tdi.callStack.removeBack();
	}
}

class TaskDebugInfo {
	Task task;
	string name;
	Vector!string breadcrumbs;
	Vector!string callStack;
	SysTime created;
	SysTime lastResumed;
	size_t memoryUsage;
}

void taskEventCallback(TaskEvent ev, Task t) nothrow {
	try {
		if (ev == TaskEvent.end || ev == TaskEvent.fail)
		{
			if (auto ptr = t.id in s_taskMap)
			{
				ThreadMem.free(*ptr);
				s_taskMap.remove(t.id);
			}
		}
		else if (ev == TaskEvent.start) {
			TaskDebugInfo tdi = ThreadMem.alloc!TaskDebugInfo();
			tdi.task = t;
			tdi.name = "Core";
			tdi.created = Clock.currTime();
			tdi.lastResumed = Clock.currTime();
			s_taskMap[t.id] = tdi;
		}
		else if (ev == TaskEvent.resume) {
			if (auto ptr = t.id in s_taskMap)
			{
				ptr.lastResumed = Clock.currTime();
			}
		}
	} catch (Throwable e) {
		try writeln(e.toString()); catch {}
	}
}

void onFree(size_t sz) {
	if (Task.getThis() == Task()) return;
	if (auto t = Task.getThis().id in s_taskMap) {
		t.memoryUsage -= sz;
	}
}

void onAlloc(size_t sz) {
	if (Task.getThis() == Task()) return;
	if (auto t = Task.getThis().id in s_taskMap) {
		t.memoryUsage += sz;
	}
}

HashMap!(TaskID, TaskDebugInfo, Malloc) s_taskMap;

alias TaskID = size_t[2];

TaskID id(Task t) {
	return [cast(size_t)cast(void*)t.fiber, t.taskCounter];
}

static this() {
	import core.thread;
	import memutils.allocators;
	setTaskEventCallback(&taskEventCallback);
	setPushTrace(&pushTrace);
	setPopTrace(&popTrace);

	enum NativeGC = 0x01;
	enum Lockless = 0x02;
	enum CryptoSafe = 0x03;
	getAllocator!NativeGC().setAllocSizeCallbacks(&onAlloc, &onFree);
	getAllocator!Lockless().setAllocSizeCallbacks(&onAlloc, &onFree);
	getAllocator!CryptoSafe().setAllocSizeCallbacks(&onAlloc, &onFree);

}