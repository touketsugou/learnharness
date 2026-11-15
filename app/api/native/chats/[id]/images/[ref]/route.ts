/** Native client: one submitted image's bytes, by the ref the view carries. */
import { nativeImageResponse } from "@/src/server";

export const dynamic = "force-dynamic";

export async function GET(_req: Request, ctx: { params: Promise<{ id: string; ref: string }> }): Promise<Response> {
	const { id, ref } = await ctx.params;
	return nativeImageResponse(id, ref);
}
