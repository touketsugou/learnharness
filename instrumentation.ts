/**
 * Server startup hook (Next instrumentation).
 *
 * Cloud mode (LH_REMOTE_TOKEN) goes first: it validates the token and
 * prepares uploads/file-access defaults before the server handles requests,
 * and a bad token fails boot. Desktop and plain dev servers skip the import.
 *
 * Plugins use the documented per-server initialization hook. A plugin failure
 * must not prevent access to existing learning data or teaching/practice.
 */
export async function register() {
	if (process.env.NEXT_RUNTIME !== "nodejs") return;
	if (process.env.LH_REMOTE_TOKEN) {
		const { prepareRemoteMode } = await import("./src/server/remote-boot.ts");
		prepareRemoteMode();
	}
	const { initializeModelCatalog } = await import("./src/server/remote-model-catalog.ts");
	initializeModelCatalog();
	const { initializePlugins } = await import("./src/server/plugins.ts");
	try { await initializePlugins(); }
	catch (error) { console.error("[plugins] Initialization failed; plugin management will report the error:", error); }
}
