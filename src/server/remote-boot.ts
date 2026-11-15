import fs from "node:fs";
import { UPLOADS_DIR } from "../../config.ts";
import { readFileAccessSettings, readSettings, writeSettings } from "../store/settings.ts";
import { assertRemoteConfig, remoteConfig } from "./remote-access.ts";

/**
 * Cloud-mode boot (instrumentation.ts → register): refuse a conflicting or
 * weak token, create the uploads folder, and — only when the user has never
 * saved a file-access preference — persist the cloud default "learner file
 * tools may read uploads only" (owner 2026-11-07: written to settings so the
 * Settings page shows the real policy; an existing preference is never
 * touched, and an unreadable settings file stays blocked as it is).
 */
export function prepareRemoteMode(env: Record<string, string | undefined> = process.env): void {
	assertRemoteConfig(env);
	if (remoteConfig(env).mode !== "on") return;
	fs.mkdirSync(UPLOADS_DIR, { recursive: true, mode: 0o700 });
	seedCloudFileAccess();
}

export function seedCloudFileAccess(uploadsDir: string = UPLOADS_DIR): boolean {
	if (!readFileAccessSettings().ok) return false;
	const record = readSettings();
	if (record?.agent?.fileAccess !== undefined) return false;
	writeSettings({ ...(record ?? {}), agent: { ...(record?.agent ?? {}), fileAccess: { restricted: true, folders: [uploadsDir] } } });
	return true;
}
