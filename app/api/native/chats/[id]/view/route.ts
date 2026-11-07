/** Native client: the server-projected session view (src/core/contracts/native.ts). */
import { nativeViewResponse } from "@/src/server";

export const dynamic = "force-dynamic";

export async function GET(_req: Request, ctx: { params: Promise<{ id: string }> }): Promise<Response> {
	const { id } = await ctx.params;
	return nativeViewResponse(id);
}
