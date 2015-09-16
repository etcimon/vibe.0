module vibe.db.redis.sessionstore;

import vibe.data.json;
import vibe.db.redis.redis;
import vibe.http.session;
import core.time;
import std.typecons : Nullable;
import std.variant;


final class RedisSessionStore : SessionStore {
	private {
		RedisDatabase m_db;
		Duration m_expirationTime = Duration.max;
	}

	this(string redis_url, long database)
	{
		m_db = connectRedis(redis_url).getDatabase(database);
	}

	/** The duration without access after which a session expires.
	*/
	@property Duration expirationTime() const { return m_expirationTime; }
	/// ditto
	@property void expirationTime(Duration dur) { m_expirationTime = dur; }

	@property SessionStorageType storageType() const { return SessionStorageType.json; }

	Session create()
	{
		auto s = createSessionInstance();
		m_db.hmset("S_" ~ s.id, "S_" ~ s.id, "S_" ~ s.id); // set place holder to avoid create empty hash
		assert(m_db.exists("S_" ~ s.id));
		if (m_expirationTime != Duration.max)
			m_db.expire("S_" ~ s.id, m_expirationTime);
		return s;
	}

	Session open(string id)
	{
		if (m_db.exists("S_" ~ id)) {
			if (m_expirationTime != Duration.max)
				m_db.expire("S_" ~ id, m_expirationTime);
			return createSessionInstance("S_" ~ id);
		}
		return Session.init;
	}

	void set(string id, string name, Variant value)
	{
		m_db.hset("S_" ~ id, name, value.get!Json.toString());
	}

	Variant get(string id, string name, lazy Variant defaultVal)
	{
		auto v = m_db.hget!(Nullable!string)("S_" ~ id, name);
		return v.isNull ? defaultVal : Variant(parseJsonString(v.get));
	}

	bool isKeySet(string id, string key)
	{
		return m_db.hexists("S_" ~ id, key);
	}

	void destroy(string id)
	{
		m_db.del("S_" ~ id);
	}

	int delegate(int delegate(ref string key, ref Variant value)) iterateSession(string id)
	{
		assert(false, "Not available for RedisSessionStore");
	}

	int iterateSession(string id, scope int delegate(string key) del)
	{
		auto res = m_db.hkeys("S_" ~ id);
		while (!res.empty) {
			auto key = res.front;
			res.popFront();
			if (auto ret = del(key))
				return ret;
		}
		return 0;
	}
}
