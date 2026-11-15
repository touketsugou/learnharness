/**
 * smoke-remote.mjs — prove a running cloud-mode server (LH_REMOTE_TOKEN) is
 * gated and serves the web and native surfaces (iOS client, 2026-11-07).
 *
 *   LH_REMOTE_TOKEN=<token> node scripts/smoke-remote.mjs [base-url]
 *
 * base-url defaults to http://127.0.0.1:3000. Read-mostly: it creates one
 * throwaway session (deleted again) and records ONE failed sign-in (counts
 * toward the server's global login throttle). Exits non-zero on any failure.
 */
const base = (process.argv[2] ?? "http://127.0.0.1:3000").replace(/\/$/, "");
const token = process.env.LH_REMOTE_TOKEN;
if (!token) {
	console.error("[smoke-remote] set LH_REMOTE_TOKEN to the server's token");
	process.exit(2);
}
const bearer = { Authorization: `Bearer ${token}` };
const origin = new URL(base).origin;
let failures = 0;

function check(name, ok, detail = "") {
	console.log(`${ok ? "ok  " : "FAIL"} ${name}${detail ? ` — ${detail}` : ""}`);
	if (!ok) failures++;
}

async function call(path, init = {}) {
	return fetch(`${base}${path}`, { redirect: "manual", ...init });
}

try {
	const anonymousApi = await call("/api/settings");
	check("anonymous API is refused", anonymousApi.status === 401, `status ${anonymousApi.status}`);

	const bearerApi = await call("/api/settings", { headers: bearer });
	check("Bearer token is accepted", bearerApi.status === 200, `status ${bearerApi.status}`);

	const anonymousPage = await call("/");
	const location = anonymousPage.headers.get("location") ?? "";
	check("anonymous page redirects to sign-in", anonymousPage.status === 303 && new URL(location, base).pathname === "/login", `${anonymousPage.status} ${location}`);

	const login = await call("/login");
	check("sign-in page is served", login.status === 200 && (login.headers.get("content-type") ?? "").includes("text/html"), `status ${login.status}`);

	const form = (value) => ({
		method: "POST",
		headers: { "Content-Type": "application/x-www-form-urlencoded", Origin: origin },
		body: new URLSearchParams({ token: value, next: "/" }).toString(),
	});
	const wrong = await call("/api/remote/login", form("not-the-token"));
	check("wrong token gets no cookie", wrong.status === 303 && !wrong.headers.get("set-cookie"), `status ${wrong.status}`);

	const right = await call("/api/remote/login", form(token));
	const setCookie = right.headers.get("set-cookie") ?? "";
	const cookie = setCookie.split(";")[0];
	check("right token sets the session cookie", right.status === 303 && cookie.startsWith("lh_session=") && /HttpOnly/i.test(setCookie), `status ${right.status}`);

	const page = await call("/", { headers: { Cookie: cookie } });
	check("cookie opens the web app", page.status === 200, `status ${page.status}`);

	const crossSite = await call("/api/chats", { method: "POST", headers: { Cookie: cookie, Origin: "https://evil.invalid", "Content-Type": "application/json" }, body: "{}" });
	check("cross-site cookie write is refused", crossSite.status === 403, `status ${crossSite.status}`);

	const subscriptions = await call("/api/subscriptions", { headers: { ...bearer, "x-learnharness-subscriptions": "1" } });
	const subs = subscriptions.status === 200 ? await subscriptions.json() : null;
	check("ChatGPT subscription is unavailable", subs?.chatgpt?.available === false, `status ${subscriptions.status}`);

	const created = await call("/api/chats", { method: "POST", headers: { ...bearer, "Content-Type": "application/json" }, body: JSON.stringify({ title: "smoke-remote" }) });
	const chat = created.status === 200 ? await created.json() : null;
	check("session can be created", typeof chat?.id === "string", `status ${created.status}`);
	if (chat?.id) {
		const view = await call(`/api/native/chats/${chat.id}/view`, { headers: bearer });
		const body = view.status === 200 ? await view.json() : null;
		check("native view is served", body?.version === 1 && body?.chatId === chat.id && body?.status === "idle", `status ${view.status}`);
		const stream = await call(`/api/native/chats/${chat.id}/stream`, { headers: bearer });
		const text = stream.status === 200 ? await stream.text() : "";
		check("native stream settles an idle session", text.includes('"type":"settled"') && text.trimEnd().endsWith("data: [DONE]"), `status ${stream.status}`);
		const removed = await call(`/api/chats/${chat.id}?mode=delete-nodes`, { method: "DELETE", headers: bearer });
		check("throwaway session is deleted", removed.status === 200, `status ${removed.status}`);
	}
} catch (error) {
	check("server reachable", false, error instanceof Error ? error.message : String(error));
}

console.log(failures === 0 ? "[smoke-remote] all checks passed" : `[smoke-remote] ${failures} check(s) failed`);
process.exit(failures === 0 ? 0 : 1);
