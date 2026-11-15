import {
	clearedSessionCookieHeader,
	loginRetryAfterSeconds,
	recordLoginFailure,
	remoteConfig,
	safeNextPath,
	sessionCookieHeader,
} from "./remote-access.ts";
import { timingSafeEqual } from "node:crypto";

/**
 * Cloud-mode browser sign-in (owner 2026-11-07): a self-contained HTML page
 * served by a route handler — outside the root layout, so no app shell,
 * sidebar or event subscription runs before the cookie exists — and a form
 * POST that trades the access token for the derived session cookie.
 */

const PAGE_HEADERS = {
	"Content-Type": "text/html; charset=utf-8",
	"Cache-Control": "no-store",
	"Referrer-Policy": "no-referrer",
	"X-Content-Type-Options": "nosniff",
	"X-Frame-Options": "DENY",
	"Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
};

const ERRORS: Record<string, string> = {
	invalid: "That token is not valid.",
	locked: "Too many failed attempts. Try again in a few minutes.",
	signed_out: "You are signed out.",
};

function escapeHTML(value: string): string {
	return value.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
}

function notFound(): Response {
	return Response.json({ error: "Not found" }, { status: 404, headers: { "Cache-Control": "no-store" } });
}

export function loginPageHTML(next: string, error?: string): string {
	const message = error && ERRORS[error] ? `<p class="error" role="alert">${escapeHTML(ERRORS[error])}</p>` : "";
	return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sign in · LearnHarness</title>
<style>
:root { color-scheme: light dark; --bg: #f7f7f5; --fg: #1d1d1b; --muted: #6b6b66; --line: #d9d9d4; --accent: #1d1d1b; --accent-fg: #f7f7f5; --error: #b3261e; }
@media (prefers-color-scheme: dark) { :root { --bg: #141413; --fg: #ececea; --muted: #9a9a94; --line: #34342f; --accent: #ececea; --accent-fg: #141413; --error: #f2b8b5; } }
* { box-sizing: border-box; }
body { margin: 0; min-height: 100dvh; display: grid; place-items: center; background: var(--bg); color: var(--fg); font: 15px/1.5 ui-sans-serif, -apple-system, system-ui, sans-serif; padding: 16px; }
main { width: 100%; max-width: 360px; }
h1 { font-size: 20px; font-weight: 600; margin: 0 0 4px; }
p { margin: 0 0 20px; color: var(--muted); }
label { display: block; font-size: 13px; margin-bottom: 6px; }
input { width: 100%; padding: 10px 12px; border: 1px solid var(--line); border-radius: 8px; background: transparent; color: var(--fg); font: 14px ui-monospace, SFMono-Regular, Menlo, monospace; }
input:focus { outline: 2px solid var(--fg); outline-offset: 1px; }
button { margin-top: 16px; width: 100%; padding: 10px 12px; border: 0; border-radius: 8px; background: var(--accent); color: var(--accent-fg); font: inherit; font-weight: 600; cursor: pointer; }
.error { color: var(--error); margin: 0 0 16px; }
</style>
</head>
<body>
<main>
<h1>LearnHarness</h1>
<p>Enter the access token configured on this server.</p>
${message}<form method="post" action="/api/remote/login">
<label for="token">Access token</label>
<input id="token" name="token" type="password" autocomplete="current-password" autofocus required spellcheck="false">
<input type="hidden" name="next" value="${escapeHTML(next)}">
<button type="submit">Sign in</button>
</form>
</main>
</body>
</html>`;
}

export function loginPageResponse(request: Request): Response {
	if (remoteConfig().mode !== "on") return notFound();
	const params = new URL(request.url).searchParams;
	return new Response(loginPageHTML(safeNextPath(params.get("next")), params.get("error") ?? undefined), { status: 200, headers: PAGE_HEADERS });
}

/** `location` is always a same-site relative path (safeNextPath or /login). */
function redirect(location: string, extra: Record<string, string> = {}): Response {
	return new Response(null, { status: 303, headers: { Location: location, "Cache-Control": "no-store", ...extra } });
}

function loginRedirect(error: string, next: string): Response {
	const params = new URLSearchParams({ error, next });
	return redirect(`/login?${params.toString()}`);
}

function tokenMatches(supplied: string, token: string): boolean {
	const a = Buffer.from(supplied);
	const b = Buffer.from(token);
	return a.length === b.length && timingSafeEqual(a, b);
}

const MAX_FORM_BYTES = 4096;

export async function loginSubmitResponse(request: Request, now: number = Date.now()): Promise<Response> {
	const config = remoteConfig();
	if (config.mode !== "on") return notFound();
	const type = request.headers.get("content-type")?.split(";")[0]?.trim();
	if (type !== "application/x-www-form-urlencoded") return Response.json({ error: "Expected a form submission." }, { status: 415 });
	if (Number(request.headers.get("content-length")) > MAX_FORM_BYTES) return Response.json({ error: "Request too large." }, { status: 413 });
	const raw = await request.text();
	if (raw.length > MAX_FORM_BYTES) return Response.json({ error: "Request too large." }, { status: 413 });
	const form = new URLSearchParams(raw);
	const next = safeNextPath(form.get("next"));
	const retryAfter = loginRetryAfterSeconds(now);
	if (retryAfter > 0) {
		const response = loginRedirect("locked", next);
		response.headers.set("Retry-After", String(retryAfter));
		return response;
	}
	const supplied = form.get("token")?.trim() ?? "";
	if (!tokenMatches(supplied, config.token)) {
		recordLoginFailure(now);
		return loginRedirect("invalid", next);
	}
	return redirect(next, { "Set-Cookie": sessionCookieHeader(config.token) });
}

export function logoutResponse(): Response {
	if (remoteConfig().mode !== "on") return notFound();
	return redirect("/login?error=signed_out", { "Set-Cookie": clearedSessionCookieHeader() });
}
