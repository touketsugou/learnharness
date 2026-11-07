/** Native client: upload learner files; returns their server paths. */
import { nativeUploadResponse } from "@/src/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export function POST(request: Request): Promise<Response> {
	return nativeUploadResponse(request);
}
