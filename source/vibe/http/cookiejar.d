﻿/**
	CookieJar implementation

	Copyright: © 2015 RejectedSoftware e.K., GlobecSys Inc
	Authors: Sönke Ludwig, Etienne Cimon
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
*/
module vibe.http.cookiejar;

import vibe.core.log;
import vibe.http.common;
import vibe.utils.memory;
import vibe.utils.array;
import vibe.utils.dictionarylist : icmp2;
import vibe.core.file;
import vibe.inet.message;
import vibe.stream.memory;
import vibe.stream.wrapper;
import vibe.stream.operations;
import vibe.http.cookiejar_dates;
import std.file : getcwd;
import vibe.core.sync;
import std.algorithm;
import std.datetime;
import std.typecons;
import std.conv : parse, to;
import std.exception;

interface CookieJar : CookieStore
{
	/// Get all valid cookies corresponding to the specified criteria
	/// Note: '*' is used as a wildcard strictly when used alone
	CookiePair[] find(string domain = "*", string name = "*", string path = "/", bool secure = false, bool http_only = false);

	/// Removes all valid cookies corresponding to the specified search criteria
	/// Note: '*' is used as a wildcard strictly when used alone
	void remove(string domain = "*", string name = "*", string path = "/", bool secure = false, bool http_only = false);

	/// Add a custom cookie, replaces the old one if it collides
	void setCookie(string name, Cookie cookie);

	/// Removes all session cookies (that were set without 'expires')
	void clearSession();

	/// Removes all invalid cookies (that are now expired)
	void cleanup();
}

struct CookiePair
{
	string name;
	Cookie value;
}

class FileCookieJar : CookieJar
{
private:
	Path m_filePath;
	RecursiveTaskMutex m_writeLock;
public:
	@property const(Path) path() const { return m_filePath; }

	void get(string host, string path, bool secure, void delegate(string) send_to) const
	{
		logTrace("Get cookies (concat) for host: %s path: %s secure: %s", host, path, secure);
		import std.array : Appender;
		StrictCookieSearch search = StrictCookieSearch("*", host, path, secure);
		Appender!string app;
		app.reserve(128);
		bool flag;

		auto ret = readCookies( (CookiePair cookie) {
				if (search.match(cookie)) {
					//logDebug("Search matched cookie: %s", cookie.name);
					if (flag) {
						app ~= "; ";
					}
					else flag = true;
					app ~= cookie.name;
					app ~= '=';
					app ~= cookie.value.value;
				}
				return false;
			});
		assert(ret.length == 0);
		// the data will be copied upon being received through the callback
		send_to(app.data);

	}

	void get(string host, string path, bool secure, void delegate(string[]) send_to) const
	{
		logTrace("Get cookies for host: %s path: %s secure: %s", host, path, secure);
		import std.array : Appender;
		StrictCookieSearch search = StrictCookieSearch("*", host, path, secure);
		Appender!(string[]) app;
		scope(exit) {
			foreach (ref string kv; app.data)
			{
				freeArray(defaultAllocator(), kv);
			}
		}

		auto ret = readCookies( (CookiePair cookie) {
				if (search.match(cookie)) {
					//logDebug("Search matched cookie: %s", cookie.name);
					char[] kv = allocArray!char(defaultAllocator(), cookie.name.length + 1 + cookie.value.value.length);
					kv[0 .. cookie.name.length] = cookie.name[];
					kv[cookie.name.length] = '=';
					kv[cookie.name.length + 1 .. $] = cookie.value.value[];
					app ~= cast(string) kv;
				}
				return false;
			});
		assert(ret.length == 0);

		send_to(app.data);
	}
	
	/// Sets the cookies using the provided Set-Cookie: header value entry
	void set(string host, string set_cookie)
	{
		m_writeLock.lock();
		scope(exit) m_writeLock.unlock();
		auto cookie_local = FreeListObjectAlloc!Cookie.alloc();
		scope(exit) FreeListObjectAlloc!Cookie.free(cookie_local);
		parseSetCookieString(set_cookie, cookie_local, (CookiePair cookie) {
				if (cookie.value.domain is null || cookie.value.domain == "")
					cookie.value.domain = host;
				setCookie(cookie.name, cookie.value);
			});
	}

	this(Path path)
	{
		m_writeLock = new RecursiveTaskMutex();
		m_filePath = path;

		if (!existsFile(m_filePath)) 
			create(path);
		
		cleanup();
		//logDebug("Using cookie jar on file: %s", m_filePath.toNativeString());
	}

	void create(Path path) const {
		int tries;
		bool success;
		do {
			try { // touch
				auto touch = openFile(path, FileMode.createTrunc);
				touch.close();
				success = true;
			} catch (Exception e) { 
				if (++tries == 3) throw e; 
			}
		} while(!success && tries < 3);
	}

	this(string path)
	{
		version(Posix)
			if (!path.canFind('/') || path.startsWith("./"))
				path = getcwd() ~ "/" ~ path;

		this(Path(path));
	}

	CookiePair[] find(string domain = "*", string name = "*", string path = "/", bool secure = false, bool http_only = false)
	{
		StrictCookieSearch search = StrictCookieSearch(name, domain, path, secure, http_only);
		return readCookies(&search.match);
	}

	void setCookie(string name, Cookie cookie)
	{
		m_writeLock.lock();
		scope(exit) m_writeLock.unlock();

		if (!existsFile(m_filePath))
			create(m_filePath);
		else {
			StrictCookieSearch search = StrictCookieSearch(name, cookie.domain, cookie.path, cookie.secure, cookie.httpOnly);
			removeCookies(&search.match);
		}
		if (cookie.maxAge) {
			cookie.expires = (Clock.currTime(UTC()) + dur!"seconds"(cookie.maxAge)).toRFC822DateTimeString();
		}
		else if (!cookie.maxAge && (!cookie.expires || cookie.expires == ""))
		{
			cookie.expires = "Thu, 01 Jan 1970 00:00:00 GMT";
		}

		{
			FileStream stream;
			scope(exit) {
				if (stream && stream.isOpen)
					stream.close();
			}
			bool success;
			int tries;
			do {
				try {
					stream = openFile(m_filePath, FileMode.append);
					success = true;
				} catch (Exception e) { if (++tries == 3) throw e; }
			} while(!success && tries < 3);

			auto range = StreamOutputRange(stream);
			logTrace("writing cookie: %s", name);
			cookie.writeString(&range, name, false);
			range.put('\n');
		}
	}

	void remove(string domain = "*", string name = "*", string path = "/", bool secure = false, bool http_only = false)
	{
		m_writeLock.lock();
		scope(exit) m_writeLock.unlock();
		StrictCookieSearch search = StrictCookieSearch(name, domain, path, secure, http_only);
		return removeCookies(&search.match);
	}

	void clearSession()
	{
		m_writeLock.lock();
		scope(exit) m_writeLock.unlock();
		removeCookies( (CookiePair cookie) { return parseCookieDate(cookie.value.expires) == epoch_parsed; } );
	}

	void cleanup()
	{
		m_writeLock.lock();
		scope(exit) m_writeLock.unlock();
		StrictCookieSearch search;
		search.expires = Clock.currTime(UTC()).toRFC822DateTimeString(); // find cookies with expiration before now, excluding session cookies
		removeCookies( &search.match );
	}

	// read cookies from the file, allocating on the GC only for the selection
	CookiePair[] readCookies(bool delegate(CookiePair) predicate) const {
		import std.array : Appender;
		if (!existsFile(m_filePath)) {
			create(m_filePath);
			return CookiePair[].init;
		}
		Appender!(CookiePair[]) cookies;
		ubyte[2048] buffer = void;
		ubyte[] contents = buffer[0 .. buffer.length];
		auto carry_over = AllocAppender!(ubyte[])(defaultAllocator());
		scope(exit) carry_over.reset(AppenderResetMode.freeData);
		PoolAllocator pool = FreeListObjectAlloc!PoolAllocator.alloc(4096, defaultAllocator());
		scope(exit) FreeListObjectAlloc!PoolAllocator.free(pool);
		
		while (contents.length == 2048)
		{
			scope(exit) pool.reset();
			contents = readFile(m_filePath, buffer);
			InputStream stream;
			scope(exit) if (stream) FreeListObjectAlloc!MemoryStream.free(cast(MemoryStream)stream);
			if (carry_over.data.length > 0) {
				carry_over.put(contents);
				stream = cast(InputStream)FreeListObjectAlloc!MemoryStream.alloc(carry_over.data);
				carry_over.reset(AppenderResetMode.reuseData);
			}
			else
				stream = cast(InputStream)FreeListObjectAlloc!MemoryStream.alloc(contents);
			size_t total_read;

			// loop for each cookie (line) found until the end of the buffer
			while(total_read < contents.length) {
				if (stream.peek().countUntil('\n') == -1)
				{
					carry_over.put(contents[total_read .. $]);
					break;
				}
				string cookie_str;
				try 
					cookie_str = cast(string) stream.readLine(4096, "\n", pool);
				catch(Exception e) {
					carry_over.put(contents[total_read .. $]);
					break;
				}
				total_read += cookie_str.length;
				
				auto getVal = (CookiePair cookiepair) {
					if (predicate(cookiepair)) {
						// copy the cookie_str on the GC and parse again
						Cookie cookie2 = new Cookie;
						// use the specified allocator for the payload
						char[] cookie_str_alloc = cast(char[])cookie_str.dup;
						auto app = (CookiePair gcpair) {
							// append the result to the `cookies`
							cookies ~= gcpair;
						};
						parseSetCookieString(cast(string)cookie_str_alloc, cookie2, app);
					}
				};
				
				{
					Cookie cookie = FreeListObjectAlloc!Cookie.alloc();
					scope(exit) FreeListObjectAlloc!Cookie.free(cookie);
					parseSetCookieString(cookie_str, cookie, getVal);
				}
			}
		}
		
		return cookies.data;
	}

	// removes cookies by skipping those that test true for specified predicate
	void removeCookies(bool delegate(CookiePair) predicate) {
		if (!existsFile(m_filePath)) {
			create(m_filePath);
			return;
		}
		m_writeLock.lock();
		scope(exit) m_writeLock.unlock();

		ubyte[2048] buffer = void;
		ubyte[] contents = buffer[0 .. buffer.length];
		auto carry_over = AllocAppender!(ubyte[])(defaultAllocator());
		scope(exit) 
			carry_over.reset(AppenderResetMode.freeData);
		PoolAllocator pool = FreeListObjectAlloc!PoolAllocator.alloc(4096, defaultAllocator());
		scope(exit) FreeListObjectAlloc!PoolAllocator.free(pool);

		FileStream new_file = createTempFile();
		bool new_file_closed;
		scope(exit) if (!new_file_closed) new_file.close();
		AllocAppender!(ubyte[]) new_file_data = AllocAppender!(ubyte[])(defaultAllocator());
		scope(exit) new_file_data.reset(AppenderResetMode.freeData);

		while (contents.length == 2048)
		{
			scope(exit) pool.reset();
			contents = readFile(m_filePath, buffer);
		
			InputStream stream;
			scope(exit) if (stream) FreeListObjectAlloc!MemoryStream.free(cast(MemoryStream)stream);
			if (carry_over.data.length > 0) {
				carry_over.put(contents);
				stream = FreeListObjectAlloc!MemoryStream.alloc(carry_over.data); // todo: Avoid this GC allocation
				carry_over.reset(AppenderResetMode.reuseData);
			}
			else
				stream = FreeListObjectAlloc!MemoryStream.alloc(contents);
			size_t total_read;

			// loop for each cookie (line) found until the end of the buffer
			while(total_read < contents.length) {
				if (stream.peek().countUntil('\n') == -1)
				{
					carry_over.put(contents[total_read .. $]);
					break;
				}
				string cookie_str;
				try
					cookie_str = cast(string) stream.readLine(4096, "\n", pool);
				catch(Exception e) {
					carry_over.put(contents[total_read .. $]);
					break;
				}
				total_read += cookie_str.length;
				auto getVal = (CookiePair cookiepair) {
					if (!predicate(cookiepair)) {
						new_file_data.put(cast(ubyte[])cookie_str);
						new_file_data.put('\n');
						if (new_file_data.data.length >= 256) {
							new_file.write(cast(ubyte[]) new_file_data.data);
							new_file.flush();
							new_file_data.reset(AppenderResetMode.reuseData);
						}
					}
				};
				
				{
					Cookie cookie = FreeListObjectAlloc!Cookie.alloc();
					scope(exit) FreeListObjectAlloc!Cookie.free(cookie);
					parseSetCookieString(cookie_str, cookie, getVal);
				}
			}
		}
		new_file.write(cast(ubyte[]) new_file_data.data);
		new_file.finalize();
		removeFile(m_filePath);
		new_file.close();
		new_file_closed = true;
		moveFile(new_file.path, m_filePath);
	}

}


class MemoryCookieJar : CookieJar
{
	import vibe.core.file : openFile, removeFile, Path;
	import memutils.unique:Unique;
private:
	CookiePair[] m_cookies;
	RecursiveTaskMutex m_writeLock;

	static void deflateFile(Path src, Path dst) {
		import vibe.stream.zlib : GzipOutputStream;
		Unique!FileStream f = openFile(src, FileMode.read);
		Unique!FileStream f2 = openFile(dst, FileMode.createTrunc);
		Unique!GzipOutputStream deflate = new GzipOutputStream(*f2);
		deflate.write(*f);
		deflate.finalize();
	}
	static void inflateFile(Path src, Path dst) {
		import vibe.stream.zlib : GzipInputStream;
		Unique!FileStream f = openFile(src, FileMode.read);
		Unique!FileStream f2 = openFile(dst, FileMode.createTrunc);
		Unique!GzipInputStream inflate = new GzipInputStream(*f);
		f2.write(*inflate);
		f2.finalize();
	}
public:
	static MemoryCookieJar loadFromGzip(Path cj) {
		MemoryCookieJar ret = new MemoryCookieJar;
		Path cj2 = Path(cj.toString() ~ ".1");
		inflateFile(cj, cj2);
		Unique!FileCookieJar filecj = new FileCookieJar(cj2);
		ret.m_cookies = filecj.readCookies((CookiePair cookie) {
				return true;
			});
		removeFile(cj2);
		return ret;
	}

	void saveToGzip(Path cj) {
		Path cj2 = Path(cj.toString() ~ ".1");
		Unique!FileCookieJar filecj = new FileCookieJar(cj2);
		foreach(CookiePair cp; m_cookies) {
			filecj.setCookie(cp.name, cp.value);
		}
		deflateFile(cj2, cj);
		removeFile(cj2);
	}

	void get(string host, string path, bool secure, void delegate(string) send_to) const
	{
		logTrace("Get cookies (concat) for host: %s path: %s secure: %s", host, path, secure);
		import std.array : Appender;
		StrictCookieSearch search = StrictCookieSearch("*", host, path, secure);
		Appender!string app;
		app.reserve(128);
		bool flag;
		
		auto ret = readCookies( (CookiePair cookie) {
				if (search.match(cookie) && cookie.value.value.length > 0) {
					//logDebug("Search matched cookie: %s", cookie.name);
					if (flag) {
						app ~= "; ";
					}
					else flag = true;
					app ~= cookie.name;
					app ~= '=';
					app ~= cookie.value.value;
				}
				return false;
			});
		assert(ret.length == 0);
		// the data will be copied upon being received through the callback
		send_to(app.data);
		
	}
	
	void get(string host, string path, bool secure, void delegate(string[]) send_to) const
	{
		logTrace("Get cookies for host: %s path: %s secure: %s", host, path, secure);
		import std.array : Appender;
		StrictCookieSearch search = StrictCookieSearch("*", host, path, secure);
		Appender!(string[]) app;
		scope(exit) {
			foreach (ref string kv; app.data)
			{
				freeArray(defaultAllocator(), kv);
			}
		}
		
		auto ret = readCookies( (CookiePair cookie) {
				if (search.match(cookie)) {
					//logDebug("Search matched cookie: %s", cookie.name);
					char[] kv = allocArray!char(defaultAllocator(), cookie.name.length + 1 + cookie.value.value.length);
					kv[0 .. cookie.name.length] = cookie.name[];
					kv[cookie.name.length] = '=';
					kv[cookie.name.length + 1 .. $] = cookie.value.value[];
					app ~= cast(string) kv;
				}
				return false;
			});
		assert(ret.length == 0);
		
		send_to(app.data);
	}
	
	/// Sets the cookies using the provided Set-Cookie: header value entry
	void set(string host, string set_cookie)
	{
		m_writeLock.lock();
		scope(exit) m_writeLock.unlock();
		auto cookie_ref = new Cookie;
		parseSetCookieString(set_cookie.idup, cookie_ref, (CookiePair cookie) {
				if (cookie.value.domain is null || cookie.value.domain == "")
					cookie.value.domain = host;
				setCookie(cookie.name, cookie.value);
			});
	}
	
	this()
	{
		m_writeLock = new RecursiveTaskMutex();
				
		cleanup();
	}
	
	CookiePair[] find(string domain = "*", string name = "*", string path = "/", bool secure = false, bool http_only = false)
	{
		StrictCookieSearch search = StrictCookieSearch(name, domain, path, secure, http_only);
		return readCookies(&search.match);
	}
	
	void setCookie(string name, Cookie cookie)
	{
		if (cookie !is null)
			m_cookies ~= CookiePair(name, cookie);
	}
	
	void remove(string domain = "*", string name = "*", string path = "/", bool secure = false, bool http_only = false)
	{
		m_writeLock.lock();
		scope(exit) m_writeLock.unlock();
		StrictCookieSearch search = StrictCookieSearch(name, domain, path, secure, http_only);
		return removeCookies(&search.match);
	}
	
	void clearSession()
	{
		m_writeLock.lock();
		scope(exit) m_writeLock.unlock();
		removeCookies( (CookiePair cookie) { return parseCookieDate(cookie.value.expires) == epoch_parsed; } );
	}
	
	void cleanup()
	{
		m_writeLock.lock();
		scope(exit) m_writeLock.unlock();
		StrictCookieSearch search;
		search.expires = Clock.currTime(UTC()).toRFC822DateTimeString(); // find cookies with expiration before now, excluding session cookies
		removeCookies( &search.match );
	}
	
	// read cookies from the file, allocating on the GC only for the selection
	CookiePair[] readCookies(bool delegate(CookiePair) predicate) const {
		import std.array : Appender;
		Appender!(CookiePair[]) cookies;
		cookies.reserve(8);
		foreach (cookie_pair; m_cookies) {
			if (predicate(cast()cookie_pair)) {
				cookies ~= cast()cookie_pair;
			}
		}
		
		return cookies.data;
	}
	
	// removes cookies by skipping those that test true for specified predicate
	void removeCookies(bool delegate(CookiePair) predicate) {
		import std.array : Appender;
		Appender!(CookiePair[]) cookies;
		cookies.reserve(m_cookies.length);
		foreach (cookie_pair; m_cookies) {
			if (!predicate(cookie_pair))
				cookies ~= cookie_pair;
		}
		m_cookies = cookies.data;
	}
	
}


struct StrictCookieSearch
{
	string name = "*";
	string domain = "*";
	string path = "/";
	bool secure = true; 
	bool httpOnly = false;
	// by default, only session/current cookies are returned
	// to get expired cookies, set this to the cutoff date after which they are expired
	string expires = "Thu, 01 Jan 1970 00:00:00 GMT";
	private SysTime expires_parsed;
	private string expires_parsed_at;

	bool match(CookiePair cookie) {

		if (expires != "" && expires && expires !is expires_parsed_at) {
			expires_parsed = parseCookieDate(expires);
			expires_parsed_at = expires;
		}

		if (name != "*") {
			if (cookie.name != name) {
				logTrace("Cookie name match failed: %s != %s", name, cookie.name);
				return false;
			}
		}
		if (domain != "*") {
			if (cookie.value.domain.length <= 0) return false;

			if (!cookie.value.domain.isCNameOf(domain))
			{
				logTrace("Domain predicate failed: %s != %s", domain, cookie.value.domain);
				return false;
			}
		}
		if (path != "/") {
			if (!path.startsWith(cookie.value.path)) {
				logTrace("Path match failed: %s != %s", path, cookie.value.path); 
				return false;
			}
		}
		if (!secure) {
			if (cookie.value.secure) {
				logTrace("Cookie secure check failed: %s != %s", secure, cookie.value.secure);
				return false;
			}
		}
		if (httpOnly) {
			if (!cookie.value.httpOnly) {
				logTrace("Cookie httpOnly check failed: %s != %s", httpOnly, cookie.value.httpOnly);
				return false;
			}
		}

		if (expires_parsed == epoch_parsed) {
			// give me valid cookies, both session and according to current time
			if (cookie.value.expires !is null && 
				cookie.value.expires != "")
			{
				SysTime cookie_expires_parsed = cookie.value.expires.parseCookieDate();
				if (cookie_expires_parsed < Clock.currTime(UTC()) &&
					cookie_expires_parsed != epoch_parsed)
				{
					logTrace("Cookie date check failed: %s != %s", expires, cookie.value.expires);
					logTrace("Cookie date check parse values: %s != %s", expires_parsed.toString(), cookie_expires_parsed.toString());
					return false;
				}
			}
		}
		else if (expires != "" && cookie.value.expires != "") {
			SysTime cookie_expires_parsed = cookie.value.expires.parseCookieDate();
			// give me expired cookies according to expires
			if (expires_parsed < cookie_expires_parsed || cookie_expires_parsed == epoch_parsed)
			{
				logTrace("Cookie date check failed: %s != %s", expires, cookie.value.expires);
				logTrace("Cookie date check parse values: %s != %s", expires_parsed.toString(), cookie_expires_parsed.toString());
				return false; // it's valid
			}
		}
		else if (expires == "")
		{
			// give me only session cookies
			if (cookie.value.expires.parseCookieDate() != epoch_parsed)
				return false;
		}
		// else don't filter expires
		//logDebug("Cookie success for name: %s", name);
		return true;
	}
}

bool isCNameOf(string canonical_name, string host) {
	// lowercase...
	bool dot_domain = canonical_name[0] == '.' && canonical_name.length > 1 && (host.length >= canonical_name.length && icmp2(host[$-canonical_name.length .. $], canonical_name) == 0 || icmp2(canonical_name[1 .. $], host) == 0);
	bool raw_domain = canonical_name[0] != '.' && icmp2(host, canonical_name) == 0;
	bool www_of_domain = host.length >= 4 && host[0 .. 4] == "www." && canonical_name[0] != '.' && icmp2(host[4 .. $], canonical_name[0 .. $]) == 0;
	bool domain_of_www = canonical_name.length >= 4 && canonical_name[0 .. 4] == "www." && icmp2(canonical_name[4 .. $], host[0 .. $]) == 0;

	return dot_domain || raw_domain || www_of_domain || domain_of_www;
}

unittest {
	// www.example.com in .example.com ?
	assert(".example.com".isCNameOf("www.example.com"));
	// example.com in .example.com ?
	assert(".example.com".isCNameOf("example.com"));
	// www.example.com in example.com ?
	assert("example.com".isCNameOf("www.example.com"));
	// anotherexample.com !in example.com ?
	assert(!"example.com".isCNameOf("anotherexample.com"));
	// example.com in www.example.com ?
	assert("www.example.com".isCNameOf("example.com"));
	// www2.example.com !in www.example.com ?
	assert(!"www.example.com".isCNameOf("www2.example.com"));
	// .com !in www.example.com ?
	assert(!"www.example.com".isCNameOf(".com"));
}


void parseSetCookieString(string set_cookie_str, ref Cookie cookie, void delegate(CookiePair) sink) {
	string name;
	size_t i;
	foreach (string part; set_cookie_str.splitter!"a is ';'"())
	{
		scope(exit) i++;
		if (part.length <= 1)
			continue;
		if (i > 0 && part[0] == ' ')
			part = part[1 .. $]; // remove whitespace
		int idx = cast(int)part.countUntil!"a is '='"();
		if (i == 0) {
			auto pair = parseNameValue(part, idx);
			name = pair[0];
			cookie.value = pair[1];
			logTrace("name: %s => Value: %s", name, cookie.value);
			continue;
		}
		
		parseAttributeValue(part, idx, cookie);
	}
	
	sink(CookiePair(name, cookie));
}

Tuple!(string, string) parseNameValue(string part, int idx) {
	string name;
	string value;
	if (idx == -1)
		return Tuple!(string, string).init;
	name = part[0 .. idx];
	if (idx == part.length)
		return Tuple!(string, string)(name, null);
	value = part[idx+1 .. $];
	return Tuple!(string, string)(name, value);
}

void parseAttributeValue(string part, int idx, ref Cookie cookie) {
	switch (idx) {
		case -1:
			// Secure
			// HttpOnly
			if (part.length == 6) {
				// Secure
				if (icmp2(part, "Secure") != 0) { logError("Cookie Secure parse failed, got %s", part); break; }
				cookie.secure = true;
			}
			else {
				// HttpOnly
				if (icmp2(part, "HttpOnly") != 0) { logError("Cookie HttpOnly parse failed, got %s", part); break; }
				cookie.httpOnly = true;
			}
			break;
		case 4: 
			// Path
			if (icmp2(part[0 .. 4], "Path") != 0 && part.length < 6) { logError("Cookie Path parse failed, got %s", part); break; }
			cookie.path = part[5 .. $];
			break;
		case 6:
			if (icmp2(part[0 .. 6], "Domain") != 0 || part.length < 8) { logError("Cookie Domain parse failed, got %s", part); break; }
			cookie.domain = part[7 .. $];
			// Domain
			break;
		case 7:
			// Max-Age
			// Expires
			if (icmp2(part[0 .. 7], "Max-Age") == 0) {
				if (part.length < 9) { logError("Cookie Max-Age parse failed, got %s", part); break; }
				string chunk = part[8 .. $];
				cookie.maxAge = chunk.parse!long;
			}
			else {
				// Expires
				if (icmp2(part[0 .. 7], "Expires") != 0 || part.length < 9) { logError("Cookie Expires parse failed, got %s", part); break; }
				cookie.expires = part[8 .. $];
			}
			break;
		default:
			logError("Cookie parse failed, got %s", part);
			break;
	}
}


static SysTime epoch_parsed;

static this() { epoch_parsed = parseCookieDate("Thu, 01 Jan 1970 00:00:00 GMT"); }