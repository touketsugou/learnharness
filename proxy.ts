import { NextResponse, type NextRequest } from "next/server";
import { desktopAPIAuthorized } from "./src/server/desktop-access.ts";
import { remoteConfig, remotePublicPath, remoteRequestVerdict } from "./src/server/remote-access.ts";

const NO_STORE = { "Cache-Control": "no-store" };

function isAPIPath(pathname: string): boolean {
	return pathname === "/api" || pathname.startsWith("/api/");
}

/** Cloud mode (LH_REMOTE_TOKEN): every page and API request needs the Bearer
 * token or the derived session cookie; cookie writes must be same-origin.
 * Pages redirect to the sign-in page, APIs answer 401/403 JSON. */
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

/** Desktop/browser mode applies to every API method, including SSE and
 * spending/settings routes. No public callback or worker bypass: internal
 * jobs call server functions, and any legitimate self-HTTP request must carry
 * the private capability. Pages pass through unchanged. */
export function proxy(request: NextRequest) {
	const remote = remoteConfig();
	if (remote.mode === "invalid") return NextResponse.json({ error: remote.error }, { status: 500, headers: NO_STORE });
	if (remote.mode === "on") return remoteProxy(request, remote.token);
	if (!isAPIPath(request.nextUrl.pathname)) return NextResponse.next();
	if (!desktopAPIAuthorized(request.headers)) {
		return NextResponse.json(
			{ error: "Desktop API access requires the trusted LearnHarness window." },
			{ status: 403, headers: NO_STORE },
		);
	}
	return NextResponse.next();
}

export const config = { matcher: ["/((?!_next/static|_next/image|favicon.ico).*)"] };
