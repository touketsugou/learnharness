/** Cloud-mode sign-in page (static HTML, outside the root layout). 404 otherwise. */
import { loginPageResponse } from "@/src/server";

export const dynamic = "force-dynamic";

export function GET(request: Request): Response {
	return loginPageResponse(request);
}
