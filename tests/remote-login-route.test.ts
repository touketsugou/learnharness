/**
 * Cloud-mode browser sign-in routes and cloud-only provider gating
 * (iOS client, 2026-11-07): the static sign-in page, token → cookie
 * exchange, the global lockout, sign-out, and ChatGPT reported unavailable.
 */
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, it } from "node:test";

const directory = await fs.mkdtemp(path.join(os.tmpdir(), "lh-remote-login-"));
process.env.LH_AUTH_FILE = path.join(directory, "auth.json");
process.env.LH_DATA_DIR = path.join(directory, "data");
delete process.env.LH_DESKTOP_SERVER; delete process.env.LH_DESKTOP_API_SECRET;
await fs.writeFile(process.env.LH_AUTH_FILE, "{}", { mode: 0o600 });
const token = "r".repeat(48);
process.env.LH_REMOTE_TOKEN = token;

const { loginPageResponse, loginSubmitResponse, logoutResponse, loginPageHTML } = await import("../src/server/remote-login.ts");
const { LOGIN_FAILURE_LIMIT, REMOTE_SESSION_COOKIE, resetLoginFailures, sessionCookieValue } = await import("../src/server/remote-access.ts");
const { subscriptionControlsResponse } = await import("../src/server/web-subscription-http.ts");
const { webSubscriptionRequest } = await import("../src/server/web-subscriptions.ts");

const base = "http://127.0.0.1:3000";

function submit(body: Record<string, string>): Promise<Response> {
	return loginSubmitResponse(new Request(`${base}/api/remote/login`, {
		method: "POST",
		headers: { "content-type": "application/x-www-form-urlencoded" },
		body: new URLSearchParams(body).toString(),
	}));
}

afterEach(() => resetLoginFailures());

describe("sign-in page", () => {
	it("serves self-contained HTML that escapes the redirect target", async () => {
		const response = loginPageResponse(new Request(`${base}/login?next=${encodeURIComponent("/chat/a?x=\"><script>")}&error=invalid`));
		assert.equal(response.status, 200);
		assert.match(response.headers.get("content-type")!, /text\/html/);
		assert.match(response.headers.get("content-security-policy")!, /frame-ancestors 'none'/);
		const html = await response.text();
		assert(!html.includes("<script>"));
		assert(html.includes("&quot;&gt;&lt;script&gt;"));
		assert(html.includes("That token is not valid."));
		assert(!loginPageHTML("/", "bogus").includes("role=\"alert\""));
	});

	it("is absent outside cloud mode", () => {
		const saved = process.env.LH_REMOTE_TOKEN;
		delete process.env.LH_REMOTE_TOKEN;
		try { assert.equal(loginPageResponse(new Request(`${base}/login`)).status, 404); }
		finally { process.env.LH_REMOTE_TOKEN = saved; }
	});
});

describe("token exchange", () => {
	it("sets the derived HttpOnly cookie and redirects to the safe target", async () => {
		const response = await submit({ token: ` ${token} `, next: "/chat/abc" });
		assert.equal(response.status, 303);
		assert.equal(response.headers.get("location"), "/chat/abc");
		const cookie = response.headers.get("set-cookie")!;
		assert(cookie.startsWith(`${REMOTE_SESSION_COOKIE}=${sessionCookieValue(token)};`));
		for (const flag of ["HttpOnly", "Secure", "SameSite=Strict", "Path=/"]) assert(cookie.includes(flag), flag);
		assert(!cookie.includes(token));
	});

	it("rejects a wrong token without a cookie and never redirects off-site", async () => {
		const response = await submit({ token: "wrong", next: "https://evil.test" });
		assert.equal(response.status, 303);
		assert.equal(response.headers.get("set-cookie"), null);
		const location = new URL(response.headers.get("location")!, base);
		assert.equal(location.pathname, "/login");
		assert.equal(location.searchParams.get("error"), "invalid");
		assert.equal(location.searchParams.get("next"), "/");
	});

	it("locks out every attempt after the failure limit, even the right token", async () => {
		for (let i = 0; i < LOGIN_FAILURE_LIMIT; i++) await submit({ token: "wrong" });
		const response = await submit({ token });
		assert.equal(response.headers.get("set-cookie"), null);
		assert.equal(new URL(response.headers.get("location")!, base).searchParams.get("error"), "locked");
		assert(Number(response.headers.get("retry-after")) > 0);
	});

	it("accepts only form submissions", async () => {
		const response = await loginSubmitResponse(new Request(`${base}/api/remote/login`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ token }) }));
		assert.equal(response.status, 415);
	});

	it("signs out by expiring the cookie", () => {
		const response = logoutResponse();
		assert.equal(response.status, 303);
		assert.match(response.headers.get("set-cookie")!, /Max-Age=0/);
		assert.equal(response.headers.get("location"), "/login?error=signed_out");
	});
});

describe("ChatGPT subscription in cloud mode", () => {
	const headers = { host: "127.0.0.1:3000", "x-learnharness-subscriptions": "1" };

	it("reports ChatGPT unavailable and refuses its controls", async () => {
		const status = await subscriptionControlsResponse(new Request(`${base}/api/subscriptions`, { headers }));
		assert.equal(status.status, 200);
		const body = await status.json() as { chatgpt: { available: boolean; accounts: unknown[] }; native: unknown[] };
		assert.equal(body.chatgpt.available, false);
		assert.deepEqual(body.chatgpt.accounts, []);
		assert(Array.isArray(body.native));
		const login = await subscriptionControlsResponse(new Request(`${base}/api/subscriptions`, {
			method: "POST",
			headers: { ...headers, origin: base, "content-type": "application/json" },
			body: JSON.stringify({ providerId: "chatgpt", op: "login" }),
		}));
		assert.equal(login.status, 400);
		assert.match(((await login.json()) as { error: string }).error, /unavailable on a cloud server/);
	});

	it("serves no ChatGPT catalog or credential lease to the agent", async () => {
		const value = await webSubscriptionRequest<{ status: { available: boolean } }>("lh:chatgpt", "status", {});
		assert.equal(value.status.available, false);
		await assert.rejects(webSubscriptionRequest("lh:chatgpt", "models", {}));
		await assert.rejects(webSubscriptionRequest("lh:chatgpt", "lease", { background: false }));
	});
});
