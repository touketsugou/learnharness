/** Cloud-mode sign-out: clears the browser session cookie. */
import { logoutResponse } from "@/src/server";

export const dynamic = "force-dynamic";

export function POST(): Response {
	return logoutResponse();
}
