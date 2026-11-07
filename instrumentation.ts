/**
 * Server startup hook (Next instrumentation). Cloud mode only: validates
 * LH_REMOTE_TOKEN and prepares uploads/file-access defaults before the
 * server handles requests. Desktop and plain dev servers skip the import.
 */
export async function register() {
	if (process.env.NEXT_RUNTIME !== "nodejs") return;
	if (!process.env.LH_REMOTE_TOKEN) return;
	const { prepareRemoteMode } = await import("./src/server/remote-boot.ts");
	prepareRemoteMode();
}
