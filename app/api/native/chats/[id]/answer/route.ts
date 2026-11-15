/** Native client: submit a raw answer; the server grades it like the web dock. */
import { nativeAnswerResponse } from "@/src/server";

export const dynamic = "force-dynamic";

export async function POST(request: Request, ctx: { params: Promise<{ id: string }> }): Promise<Response> {
	const { id } = await ctx.params;
	return nativeAnswerResponse(id, request);
}
