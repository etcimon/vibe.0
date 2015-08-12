import vibe.data.json;

import std.stdio;

void makeFromArgs(ARGS...)(string fmt, ARGS args)
{
	Json json = Json.emptyObject;
	json["fmt"] = fmt;
	json["args"] = Json.emptyArray;
	//foreach (i, arg; args) {
	//	json["args"] ~= arg;
	//}
	//json["args"] = Json[](args;
	writeln(json.toPrettyString());
}

void main()
{
	makeFromArgs("What's up %s %s %d", "you", "hello there", 5);
	Json a = 1;
	Json b = 2;
	writefln("%s %s", a.type, b.type);
	auto c = a + b;
	c = c * 2;
	writefln("%d", cast(long)c);
	
	Json[string] obj;
	obj["item1"] = a;
	obj["item2"] = "Object";
	Json parent = obj;
	parent.remove("item1");
	foreach (i; obj) writeln(i);
}
