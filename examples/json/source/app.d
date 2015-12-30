import vibe.data.json;

import std.stdio;

void main()
{
	Json a = parseJsonString(`{"id": 1142031921356158508}`);
	writeln(a.serializeToJsonString());
}
