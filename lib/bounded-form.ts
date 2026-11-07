/** A multipart body larger than the caller's byte bound. */
export class BodyLimitError extends Error {}

/** Bound actual body bytes before multipart parsing, including requests without
 * a trustworthy Content-Length. Next's proxy may truncate first; parsing that
 * incomplete body is a separate, handled refusal (SyntaxError/TypeError from
 * formData()), never a partial read. Shared by notes import and native uploads. */
export async function readBoundedForm(request: Request, maxBodyBytes: number): Promise<FormData> {
	if (Number(request.headers.get("content-length")) > maxBodyBytes) {
		void request.body?.cancel().catch(() => undefined);
		throw new BodyLimitError();
	}
	const reader = request.body?.getReader();
	if (!reader) throw new SyntaxError("Missing multipart body");
	const chunks: Uint8Array[] = [];
	let bytes = 0;
	try {
		for (;;) {
			const { done, value } = await reader.read();
			if (done) break;
			bytes += value.byteLength;
			if (bytes > maxBodyBytes) throw new BodyLimitError();
			chunks.push(value);
		}
		const body = new Uint8Array(bytes);
		let offset = 0;
		for (const chunk of chunks) {
			body.set(chunk, offset);
			offset += chunk.byteLength;
		}
		return await new Response(body, { headers: { "Content-Type": request.headers.get("content-type") ?? "" } }).formData();
	} finally {
		// Do not wait for a tee's other consumer to finish before refusing an upload.
		void reader.cancel().catch(() => undefined);
		reader.releaseLock();
	}
}
