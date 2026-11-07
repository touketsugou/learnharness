/** Native client: the turn-scoped projected-view stream (snapshot → patch* → settled). */
import { nativeStreamResponse } from "@/src/server";

export const dynamic = "force-dynamic";

export async function GET(_req: Request, ctx: { params: Promise<{ id: string }> }): Promise<Response> {
	const { id } = await ctx.params;
	return nativeStreamResponse(id);
}
