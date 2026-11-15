/** Cloud-mode sign-in: form POST of the access token → session cookie. */
import { loginSubmitResponse } from "@/src/server";

export const dynamic = "force-dynamic";

export function POST(request: Request): Promise<Response> {
	return loginSubmitResponse(request);
}
