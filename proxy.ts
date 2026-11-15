import { NextResponse, type NextRequest } from "next/server";
import { apiRequestRefusal } from "./src/server/desktop-access.ts";
import { remoteConfig, remotePublicPath, remoteRequestVerdict } from "./src/server/remote-access.ts";

const NO_STORE = { "Cache-Control": "no-store" };

function isAPIPath(pathname: string): boolean {
	return pathname === "/api" || pathname.startsWith("/api/");
}

/** Cloud mode (LH_REMOTE_TOKEN): every page and API request needs the Bearer
 * token or the derived session cookie; cookie writes must be same-origin.
 * Pages redirect to the sign-in page, APIs answer 401/403 JSON. The token is
 * the only gate here: browser-only mode's Host and Origin checks do not apply
 * (owner, 2026-11-15). The streamed plugin document route, which Proxy skips,
 * applies the same rule in createPluginDocumentRoute. */
function remoteProxy(request: NextRequest, token: string) {
	const { pathname, search } = request.nextUrl;
	if (remotePublicPath(pathname)) return NextResponse.next();
	const verdict = remoteRequestVerdict(request.method, request.headers, token);
	if (verdict.ok) return NextResponse.next();
	if (isAPIPath(pathname)) {
		return NextResponse.json(
			{ error: verdict.error },
			{ status: verdict.status, headers: verdict.status === 401 ? { ...NO_STORE, "WWW-Authenticate": "Bearer" } : NO_STORE },
		);
	}
	if (verdict.status === 403) return NextResponse.json({ error: verdict.error }, { status: 403, headers: NO_STORE });
	const login = new URL("/login", request.url);
	login.search = "";
	login.searchParams.set("next", pathname + search);
	return NextResponse.redirect(login, { status: 303, headers: NO_STORE });
}

/** Protects API methods, including SSE and spending/settings routes. The one
 * streamed document route enforces the identical all-method request policy
 * inside its handler, avoiding Next's silently truncated Proxy body clone.
 * No public callback or worker bypass: legitimate self-HTTP still needs the capability.
 * Outside cloud mode, pages pass through unchanged. */
export function proxy(request: NextRequest) {
	const remote = remoteConfig();
	if (remote.mode === "invalid") return NextResponse.json({ error: remote.error }, { status: 500, headers: NO_STORE });
	if (remote.mode === "on") return remoteProxy(request, remote.token);
	if (!isAPIPath(request.nextUrl.pathname)) return NextResponse.next();
	const refusal = apiRequestRefusal(request);
	if (refusal) {
		return NextResponse.json(
			{ error: refusal },
			{ status: 403, headers: NO_STORE },
		);
	}
	return NextResponse.next();
}

export const config = {
	// The first entry covers pages for cloud mode's sign-in gate, minus static
	// assets and /api, which the next two cover. Keep /api itself covered; exempt
	// only the exact streamed endpoint, not the documents subtree or other plugin
	// routes. Must remain static literals.
	matcher: [
		"/((?!_next/static|_next/image|favicon.ico|api(?:/|$)).*)",
		"/api",
		"/api/((?!plugins/[^/]+/documents/markdown/?$).*)",
	],
};
