/**
 * NATIVE UPLOADS (iOS client, owner 2026-11-07): the desktop app attaches
 * files by local path; a phone has no shared filesystem with the server, so
 * the native client uploads to UPLOADS_DIR and inserts the returned SERVER
 * path into the message (quoted with core/file-paths quoteFilePath, same as
 * desktop attachments). The agent reads it with its ordinary file tools —
 * in cloud mode those are limited to the uploads folder by default.
 *
 * Bounds match notes import: ≤ 25 MiB of file bytes per request inside a
 * 26 MiB multipart body. Stored as <uploads>/<yyyy-mm>/<uuid>-<safe name>.
 */
import { randomUUID } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { UPLOADS_DIR } from "../../config.ts";
import { BodyLimitError, readBoundedForm } from "../../lib/bounded-form.ts";
import { MAX_IMPORT_BODY_BYTES, MAX_IMPORT_BYTES } from "../../lib/notes-import-limits.ts";
import type { NativeUploadResult } from "../core/contracts/native.ts";

const MAX_NAME_CHARS = 120;

/** A display-safe file name: no directories, control characters or separators. */
export function safeUploadName(raw: string): string {
	const base = raw.split(/[\\/]/).pop() ?? "";
	const cleaned = base.replace(/[\u0000-\u001F\u007F:]/g, "").replace(/^\.+/, "").trim();
	if (!cleaned) return "upload";
	if (cleaned.length <= MAX_NAME_CHARS) return cleaned;
	const ext = path.extname(cleaned).slice(0, 16);
	return cleaned.slice(0, MAX_NAME_CHARS - ext.length) + ext;
}

function monthFolder(now: Date): string {
	return `${now.getUTCFullYear()}-${String(now.getUTCMonth() + 1).padStart(2, "0")}`;
}

export async function nativeUploadResponse(request: Request, options: { root?: string; now?: Date } = {}): Promise<Response> {
	let form: FormData;
	try {
		form = await readBoundedForm(request, MAX_IMPORT_BODY_BYTES);
	} catch (err) {
		const oversized = err instanceof BodyLimitError;
		return Response.json(
			{ error: oversized ? "Upload is too large. Max 25 MB per request." : "Could not read the upload. Please try again." },
			{ status: oversized ? 413 : 400 },
		);
	}
	const files = form.getAll("files").filter((f): f is File => f instanceof File);
	if (files.length === 0) return Response.json({ error: "No files" }, { status: 400 });
	if (files.reduce((total, file) => total + file.size, 0) > MAX_IMPORT_BYTES) {
		return Response.json({ error: "Upload is too large. Max 25 MB per request." }, { status: 413 });
	}
	const folder = path.join(options.root ?? UPLOADS_DIR, monthFolder(options.now ?? new Date()));
	fs.mkdirSync(folder, { recursive: true, mode: 0o700 });
	const result: NativeUploadResult = { files: [] };
	for (const file of files) {
		const name = safeUploadName(file.name);
		const target = path.join(folder, `${randomUUID()}-${name}`);
		const bytes = new Uint8Array(await file.arrayBuffer());
		fs.writeFileSync(target, bytes, { mode: 0o600, flag: "wx" });
		result.files.push({ name, path: target, bytes: bytes.byteLength });
	}
	return Response.json(result, { status: 201, headers: { "Cache-Control": "no-store" } });
}
