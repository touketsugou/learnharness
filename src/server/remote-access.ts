import { createHmac, timingSafeEqual } from "node:crypto";

/**
 * CLOUD MODE (iOS client, 2026-11-07): a single-user server on the owner's
 * own host, reached over the network by the native client (Bearer token)
 * and by a browser (HttpOnly session cookie derived from the same token).
 * Setting LH_REMOTE_TOKEN turns it on; it is mutually exclusive with the
 * Electron desktop server. Rotating the token revokes every client and
 * every browser session at once.
 *
 * Deliberately dependency-light (node:crypto only): proxy.ts imports this
 * module directly on every request.
 */

export const REMOTE_TOKEN_MIN_LENGTH = 43; // 32 random bytes, base64url
export const REMOTE_SESSION_COOKIE = "lh_session";
export const REMOTE_SESSION_MAX_AGE_SECONDS = 30 * 24 * 60 * 60;
export const LOGIN_FAILURE_LIMIT = 10;
export const LOGIN_FAILURE_WINDOW_MS = 10 * 60 * 1000;

const SESSION_LABEL = "lh-web-session-v1";
const SAFE_METHODS = new Set(["GET", "HEAD", "OPTIONS"]);

type Env = Record<string, string | undefined>;

export type RemoteConfig =
	| { mode: "off" }
	| { mode: "on"; token: string }
	| { mode: "invalid"; error: string };

export function remoteConfig(env: Env = process.env): RemoteConfig {
	const token = env.LH_REMOTE_TOKEN;
	if (token === undefined || token === "") return { mode: "off" };
	if (env.LH_DESKTOP_SERVER === "1" || env.LH_DESKTOP_API_SECRET) {
		return { mode: "invalid", error: "LH_REMOTE_TOKEN cannot be combined with the desktop server (LH_DESKTOP_SERVER / LH_DESKTOP_API_SECRET)." };
	}
	if (!/^[\x21-\x7E]+$/.test(token)) {
		return { mode: "invalid", error: "LH_REMOTE_TOKEN must be printable ASCII without spaces." };
	}
	if (token.length < REMOTE_TOKEN_MIN_LENGTH) {
		return { mode: "invalid", error: `LH_REMOTE_TOKEN must be at least ${REMOTE_TOKEN_MIN_LENGTH} characters (32 random bytes, base64url).` };
	}
	return { mode: "on", token };
}

/** Cloud-mode behavior switches. A misconfigured token still counts: the
 *  proxy refuses every request then, so nothing runs with desktop defaults. */
export function cloudMode(env: Env = process.env): boolean {
	return remoteConfig(env).mode !== "off";
}

/** Boot gate (instrumentation.ts): refuse to start on a conflicting or weak token. */
export function assertRemoteConfig(env: Env = process.env): void {
	const config = remoteConfig(env);
	if (config.mode === "invalid") throw new Error(config.error);
}

function safeEqual(a: string, b: string): boolean {
	const x = Buffer.from(a);
	const y = Buffer.from(b);
	return x.length === y.length && timingSafeEqual(x, y);
}

/** The browser session value: derived, never the token itself. */
export function sessionCookieValue(token: string): string {
	return createHmac("sha256", token).update(SESSION_LABEL).digest("base64url");
}

export function readCookie(headers: Headers, name: string): string | undefined {
	const header = headers.get("cookie");
	if (!header) return undefined;
	for (const pair of header.split(";")) {
		const index = pair.indexOf("=");
		if (index === -1) continue;
		if (pair.slice(0, index).trim() === name) return pair.slice(index + 1).trim();
	}
	return undefined;
}

export function bearerAuthorized(headers: Headers, token: string): boolean {
	const match = /^Bearer\s+(\S+)$/i.exec(headers.get("authorization")?.trim() ?? "");
	return !!match && safeEqual(match[1]!, token);
}

export function sessionCookieAuthorized(headers: Headers, token: string): boolean {
	const value = readCookie(headers, REMOTE_SESSION_COOKIE);
	return !!value && safeEqual(value, sessionCookieValue(token));
}

/** CSRF gate for cookie-authenticated writes: the Origin must name the Host
 *  the request was addressed to. Forwarded headers are never trusted (same
 *  rule as web-subscription-http.ts), so the reverse proxy must preserve Host. */
export function sameOriginRequest(headers: Headers): boolean {
	const origin = headers.get("origin");
	const host = headers.get("host");
	if (!origin || !host) return false;
	try { return new URL(origin).host.toLowerCase() === host.toLowerCase(); } catch { return false; }
}

export type RemoteVerdict = { ok: true } | { ok: false; status: 401 | 403; error: string };

export function remoteRequestVerdict(method: string, headers: Headers, token: string): RemoteVerdict {
	if (bearerAuthorized(headers, token)) return { ok: true };
	if (sessionCookieAuthorized(headers, token)) {
		if (SAFE_METHODS.has(method.toUpperCase()) || sameOriginRequest(headers)) return { ok: true };
		return { ok: false, status: 403, error: "Cross-origin request refused." };
	}
	return { ok: false, status: 401, error: "Sign-in required." };
}

/** Paths reachable without credentials in cloud mode. */
export function remotePublicPath(pathname: string): boolean {
	return pathname === "/login" || pathname === "/api/remote/login";
}

/** Only same-site relative targets survive a login redirect. */
export function safeNextPath(raw: unknown): string {
	if (typeof raw !== "string" || !raw.startsWith("/") || raw.startsWith("//") || raw.startsWith("/\\")) return "/";
	if (/[\u0000-\u001F\u007F]/.test(raw)) return "/";
	if (raw === "/login" || raw.startsWith("/login?") || raw.startsWith("/api/remote/")) return "/";
	return raw;
}

// ─── Login throttle (global, owner 2026-11-07) ──────────────────────────────
// Not per-IP: the route cannot see the socket address and forwarded headers
// can be forged. Every failure counts toward one window; while blocked even a
// correct token is refused. Bearer requests are never throttled.

const FAILURES = Symbol.for("lh.remoteLoginFailures");

function failureLog(): number[] {
	const global = globalThis as typeof globalThis & { [FAILURES]?: number[] };
	return global[FAILURES] ??= [];
}

function prune(now: number): number[] {
	const log = failureLog();
	while (log.length && log[0]! <= now - LOGIN_FAILURE_WINDOW_MS) log.shift();
	return log;
}

/** Seconds until the next login attempt is allowed; 0 when not blocked. */
export function loginRetryAfterSeconds(now: number = Date.now()): number {
	const log = prune(now);
	if (log.length < LOGIN_FAILURE_LIMIT) return 0;
	return Math.max(1, Math.ceil((log[log.length - LOGIN_FAILURE_LIMIT]! + LOGIN_FAILURE_WINDOW_MS - now) / 1000));
}

export function recordLoginFailure(now: number = Date.now()): void {
	prune(now).push(now);
}

export function resetLoginFailures(): void {
	failureLog().length = 0;
}

export function sessionCookieHeader(token: string): string {
	return `${REMOTE_SESSION_COOKIE}=${sessionCookieValue(token)}; Path=/; Max-Age=${REMOTE_SESSION_MAX_AGE_SECONDS}; HttpOnly; Secure; SameSite=Strict`;
}

export function clearedSessionCookieHeader(): string {
	return `${REMOTE_SESSION_COOKIE}=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Strict`;
}
