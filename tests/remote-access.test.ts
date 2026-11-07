/**
 * Cloud mode access gate (iOS client, 2026-11-07): token config validation,
 * Bearer + derived-cookie authentication, the cookie CSRF rule, the global
 * login throttle, and the proxy's cloud-mode responses. Desktop-mode proxy
 * behavior stays covered by desktop-api.test.ts.
 */
import assert from "node:assert/strict";
import fs from "node:fs";
import { after, afterEach, describe, it } from "node:test";
import { NextRequest } from "next/server";
import { SETTINGS_FILE } from "../config.ts";
import { proxy } from "../proxy.ts";
import {
	LOGIN_FAILURE_LIMIT,
	LOGIN_FAILURE_WINDOW_MS,
	REMOTE_SESSION_COOKIE,
	bearerAuthorized,
	cloudMode,
	loginRetryAfterSeconds,
	recordLoginFailure,
	remoteConfig,
	remoteRequestVerdict,
	resetLoginFailures,
	safeNextPath,
	sameOriginRequest,
	sessionCookieAuthorized,
	sessionCookieValue,
} from "../src/server/remote-access.ts";
import { seedCloudFileAccess } from "../src/server/remote-boot.ts";
import { readSettings, writeSettings } from "../src/store/settings.ts";

const token = "t".repeat(43);
const origin = "https://lh.example.test";

function withToken<T>(value: string | undefined, fn: () => T): T {
	const saved = process.env.LH_REMOTE_TOKEN;
	if (value === undefined) delete process.env.LH_REMOTE_TOKEN; else process.env.LH_REMOTE_TOKEN = value;
	try { return fn(); } finally {
		if (saved === undefined) delete process.env.LH_REMOTE_TOKEN; else process.env.LH_REMOTE_TOKEN = saved;
	}
}

describe("remote config", () => {
	it("is off without a token and on with a long printable one", () => {
		assert.deepEqual(remoteConfig({}), { mode: "off" });
		assert.deepEqual(remoteConfig({ LH_REMOTE_TOKEN: "" }), { mode: "off" });
		assert.deepEqual(remoteConfig({ LH_REMOTE_TOKEN: token }), { mode: "on", token });
		assert.equal(cloudMode({}), false);
		assert.equal(cloudMode({ LH_REMOTE_TOKEN: token }), true);
	});

	it("refuses short, non-printable, and desktop-combined tokens", () => {
		assert.equal(remoteConfig({ LH_REMOTE_TOKEN: "t".repeat(42) }).mode, "invalid");
		assert.equal(remoteConfig({ LH_REMOTE_TOKEN: `${token} x` }).mode, "invalid");
		assert.equal(remoteConfig({ LH_REMOTE_TOKEN: token, LH_DESKTOP_SERVER: "1" }).mode, "invalid");
		assert.equal(remoteConfig({ LH_REMOTE_TOKEN: token, LH_DESKTOP_API_SECRET: "s".repeat(64) }).mode, "invalid");
		assert.equal(cloudMode({ LH_REMOTE_TOKEN: "short" }), true, "a misconfigured token never falls back to desktop defaults");
	});
});

describe("request authentication", () => {
	const cookie = `${REMOTE_SESSION_COOKIE}=${sessionCookieValue(token)}`;

	it("accepts exactly the Bearer token", () => {
		assert(bearerAuthorized(new Headers({ authorization: `Bearer ${token}` }), token));
		assert(bearerAuthorized(new Headers({ authorization: `bearer ${token}` }), token));
		for (const value of ["", "Bearer", `Bearer ${token}x`, `Basic ${token}`, `Bearer ${token} ${token}`]) {
			assert(!bearerAuthorized(new Headers({ authorization: value }), token), value);
		}
	});

	it("accepts the derived cookie, never the raw token as a cookie", () => {
		assert.notEqual(sessionCookieValue(token), token);
		assert(sessionCookieAuthorized(new Headers({ cookie: `a=1; ${cookie}; b=2` }), token));
		assert(!sessionCookieAuthorized(new Headers({ cookie: `${REMOTE_SESSION_COOKIE}=${token}` }), token));
		assert(!sessionCookieAuthorized(new Headers({ cookie }), "u".repeat(43)), "rotating the token revokes cookies");
	});

	it("requires a same-host Origin for cookie writes only", () => {
		const host = { host: "lh.example.test" };
		assert(sameOriginRequest(new Headers({ ...host, origin })));
		assert(!sameOriginRequest(new Headers({ ...host, origin: "https://evil.test" })));
		assert(!sameOriginRequest(new Headers({ ...host, origin: "https://evil.test", "x-forwarded-host": "evil.test" })), "forwarded hosts are never trusted");
		assert(!sameOriginRequest(new Headers(host)));
		assert.deepEqual(remoteRequestVerdict("GET", new Headers({ ...host, cookie }), token), { ok: true });
		assert.deepEqual(remoteRequestVerdict("POST", new Headers({ ...host, cookie, origin }), token), { ok: true });
		assert.equal(remoteRequestVerdict("POST", new Headers({ ...host, cookie }), token).ok, false);
		assert.deepEqual(remoteRequestVerdict("POST", new Headers({ ...host, authorization: `Bearer ${token}` }), token), { ok: true });
		const anonymous = remoteRequestVerdict("GET", new Headers(host), token);
		assert(!anonymous.ok && anonymous.status === 401);
	});

	it("keeps login redirects same-site", () => {
		assert.equal(safeNextPath("/chat/abc?x=1"), "/chat/abc?x=1");
		for (const value of [undefined, "", "https://evil.test", "//evil.test", "/\\evil.test", "/login", "/login?next=/", "/api/remote/logout", "/a\nb"]) {
			assert.equal(safeNextPath(value), "/", String(value));
		}
	});
});

describe("login throttle", () => {
	afterEach(() => resetLoginFailures());

	it("blocks after the global failure limit and reopens when the window passes", () => {
		const start = 1_000_000;
		for (let i = 0; i < LOGIN_FAILURE_LIMIT - 1; i++) recordLoginFailure(start + i);
		assert.equal(loginRetryAfterSeconds(start + 100), 0);
		recordLoginFailure(start + 100);
		assert(loginRetryAfterSeconds(start + 200) > 0);
		assert.equal(loginRetryAfterSeconds(start + LOGIN_FAILURE_WINDOW_MS + 1), 0);
	});
});

describe("cloud-mode proxy", () => {
	it("redirects anonymous pages to sign-in and answers APIs with 401", () => {
		withToken(token, () => {
			const page = proxy(new NextRequest(`${origin}/chat/abc?x=1`, { headers: { host: "lh.example.test" } }));
			assert.equal(page.status, 303);
			const location = new URL(page.headers.get("location")!);
			assert.equal(location.pathname, "/login");
			assert.equal(location.searchParams.get("next"), "/chat/abc?x=1");
			const api = proxy(new NextRequest(`${origin}/api/settings`, { headers: { host: "lh.example.test" } }));
			assert.equal(api.status, 401);
			assert.equal(api.headers.get("www-authenticate"), "Bearer");
		});
	});

	it("lets the sign-in endpoints through and authenticated requests pass", () => {
		withToken(token, () => {
			const host = { host: "lh.example.test" };
			assert.equal(proxy(new NextRequest(`${origin}/login`, { headers: host })).headers.get("x-middleware-next"), "1");
			assert.equal(proxy(new NextRequest(`${origin}/api/remote/login`, { method: "POST", headers: host })).headers.get("x-middleware-next"), "1");
			assert.equal(proxy(new NextRequest(`${origin}/api/chat`, { method: "POST", headers: { ...host, authorization: `Bearer ${token}` } })).headers.get("x-middleware-next"), "1");
			const cookie = `${REMOTE_SESSION_COOKIE}=${sessionCookieValue(token)}`;
			assert.equal(proxy(new NextRequest(`${origin}/`, { headers: { ...host, cookie } })).headers.get("x-middleware-next"), "1");
			assert.equal(proxy(new NextRequest(`${origin}/api/chat`, { method: "POST", headers: { ...host, cookie, origin } })).headers.get("x-middleware-next"), "1");
			assert.equal(proxy(new NextRequest(`${origin}/api/chat`, { method: "POST", headers: { ...host, cookie, origin: "https://evil.test" } })).status, 403);
		});
	});

	it("refuses everything when the token is misconfigured", () => {
		withToken("short", () => {
			assert.equal(proxy(new NextRequest(`${origin}/`)).status, 500);
			assert.equal(proxy(new NextRequest(`${origin}/api/settings`, { headers: { authorization: "Bearer short" } })).status, 500);
		});
	});
});

describe("cloud file-access seed", () => {
	let hadSettings = false;
	let savedSettings = "";
	try { savedSettings = fs.readFileSync(SETTINGS_FILE, "utf-8"); hadSettings = true; } catch { /* first boot */ }
	after(() => {
		if (hadSettings) fs.writeFileSync(SETTINGS_FILE, savedSettings, "utf-8");
		else fs.rmSync(SETTINGS_FILE, { force: true });
	});
	afterEach(() => fs.rmSync(SETTINGS_FILE, { force: true }));

	it("writes the uploads-only policy when none was ever saved, keeping other preferences", () => {
		assert.equal(seedCloudFileAccess("/srv/uploads"), true);
		assert.deepEqual(readSettings()?.agent?.fileAccess, { restricted: true, folders: ["/srv/uploads"] });
		fs.rmSync(SETTINGS_FILE, { force: true });
		writeSettings({ version: 1, general: { autoUpdate: false } });
		assert.equal(seedCloudFileAccess("/srv/uploads"), true);
		const record = readSettings();
		assert.deepEqual(record?.agent?.fileAccess, { restricted: true, folders: ["/srv/uploads"] });
		assert.equal(record?.general?.autoUpdate, false);
	});

	it("never replaces a saved preference or repairs a corrupt file", () => {
		writeSettings({ version: 1, agent: { fileAccess: { restricted: false, folders: [] } } });
		assert.equal(seedCloudFileAccess("/srv/uploads"), false);
		assert.deepEqual(readSettings()?.agent?.fileAccess, { restricted: false, folders: [] });
		fs.writeFileSync(SETTINGS_FILE, "{not json", "utf-8");
		assert.equal(seedCloudFileAccess("/srv/uploads"), false);
		assert.equal(fs.readFileSync(SETTINGS_FILE, "utf-8"), "{not json");
	});
});
