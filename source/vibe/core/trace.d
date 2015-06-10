module vibe.core.trace;

// Trace is provided by vibe.core.core
public import vibe.core.core : Trace, StackTrace;
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

		foreach (const ref Task t, const ref TaskDebugInfo tdi; s_taskMap) 
			keys ~= cast()t;
		
		return keys.data;
	}

	// Fetches the call stack of a currently yielded task
	Vector!string findCallStack(Task t) {
		scope(failure) assert(false);
		if (auto ptr = t in s_taskMap) {
			return ptr.callStack.dup;
		}
		return Vector!string(["No call stack"]);
	}

	void setTaskName(string name) {
		scope(failure) assert(false);
		if (auto tls_tdi = Task.getThis() in s_taskMap) {
			tls_tdi.name = name;
		}
	}

	void setTaskName(Task t, string name) {
		scope(failure) assert(false);
		if (auto ptr = t in s_taskMap) {
			ptr.name = name;
		}
	}

	string getTaskName(Task t = Task.getThis()) {
		scope(failure) assert(false);
		if (auto ptr = t in s_taskMap) {
			return ptr.name;
		}
		return "Invalid Task";
	}

	void addBreadcrumb(string bcrumb) {
		scope(failure) assert(false);
		if (auto tls_tdi = Task.getThis() in s_taskMap) {
			tls_tdi.breadcrumbs ~= bcrumb;
		}
	}

	void addBreadcrumb(Task t, string bcrumb) {
		scope(failure) assert(false);
		if (auto ptr = t in s_taskMap) {
			ptr.breadcrumbs ~= bcrumb;
		}
	}

	string[] getBreadcrumbs(Task t = Task.getThis()) {
		scope(failure) assert(false);
		if (auto ptr = t in s_taskMap) {
			return ptr.breadcrumbs[].dup;
		}
		return ["Invalid Task"];
	}
}

private:

bool init() {
	if (Task.getThis() == Task()) return false;
	return true;
}

void pushTrace(string info) {
	if (Task.getThis() == Task()) return;
	if (auto tls_tdi = Task.getThis() in s_taskMap) {
		tls_tdi.callStack ~= info;
	}

}

void popTrace() {
	if (Task.getThis() == Task()) return;
	if (auto tls_tdi = Task.getThis() in s_taskMap) {
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
}

void taskEventCallback(TaskEvent ev, Task t) nothrow {
	scope(failure) assert(false);
	if (ev == TaskEvent.end || ev == TaskEvent.fail)
	{
		if (auto ptr = t in s_taskMap)
		{
			ThreadMem.free(*ptr);
			s_taskMap.remove(t);
		}
	}
	else if (ev == TaskEvent.start) {
		TaskDebugInfo tdi = ThreadMem.alloc!TaskDebugInfo();
		tdi.task = t;
		tdi.name = "Core";
		tdi.created = Clock.currTime();
		tdi.lastResumed = Clock.currTime();
		s_taskMap[t] = tdi;
	}
	else if (ev == TaskEvent.resume) {
		if (auto ptr = t in s_taskMap)
		{
			ptr.lastResumed = Clock.currTime();
		}
	}
}

HashMap!(Task, TaskDebugInfo) s_taskMap;

static this() {
	import core.thread;
	setTaskEventCallback(&taskEventCallback);
	setPushTrace(&pushTrace);
	setPopTrace(&popTrace);
}