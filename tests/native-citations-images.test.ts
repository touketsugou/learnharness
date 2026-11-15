/**
 * Tutor quotes and submitted images on the native view (iOS client,
 * 2026-11-16). A learner's `[Tutor quote](lh-citation://…)` links arrive as
 * structured `citations` on the text part (UTF-16 ranges into the displayed
 * text); the text itself stays as saved. Inline base64 images arrive as
 * references the native image route serves.
 */
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import * as fs from "node:fs";
import * as path from "node:path";
import { after, describe, it } from "node:test";
import { NextRequest } from "next/server";
import { PATHS } from "../config.ts";
import { proxy } from "../proxy.ts";
import { buildNativeView, nativeImageResponse } from "../src/server/native-view.ts";
import { chatStore } from "../src/store/chats.ts";
import { serializeCitation, type TutorCitation } from "../src/core/citations.ts";
import { newThinkingMessage, type LhMessage } from "../src/core/native-messages.ts";
import type { NativeCitation, NativeViewPart } from "../src/core/contracts/native.ts";

const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };

function chat(messages: unknown[]) {
	return {
		id: "chat_citations", title: "Citations", createdAt: "2026-11-16T00:00:00.000Z", updatedAt: "2026-11-16T00:00:00.000Z", messages,
	} as never as Parameters<typeof buildNativeView>[0];
}

function citation(text: string, comment?: string): TutorCitation {
	return { version: 1, chatId: "chat_citations", messageId: "tutor_1", text, start: 0, end: text.length, prefix: "", suffix: "", ...(comment ? { comment } : {}) };
}

const tutor = {
	id: "tutor_1", role: "assistant", content: [{ type: "text", text: "为什么要先归一化？Because 🎯 scale matters." }],
	stopReason: "stop", api: "faux", provider: "faux", model: "faux", usage, timestamp: 1,
};

function userText(view: ReturnType<typeof buildNativeView>): NativeViewPart {
	return view.messages.find((m) => m.role === "user")!.parts.find((p) => p.type === "text")!;
}

describe("native tutor quotes", () => {
	it("marks each quote's range, label and quoted message, keeping the text", () => {
		const first = serializeCitation(citation("为什么要先归一化"));
		const second = serializeCitation(citation("🎯 scale matters", "我不懂这里 🤔"));
		const text = `这里没懂：${first} 还有 😀 ${second}`;
		const view = buildNativeView(chat([tutor, { id: "user_1", role: "user", content: text, timestamp: 2 }]));
		const part = userText(view);
		assert.equal(part.text, text);
		const citations = part.citations as NativeCitation[];
		assert.equal(citations.length, 2);
		assert.equal(text.slice(citations[0]!.start, citations[0]!.end), first);
		assert.equal(text.slice(citations[1]!.start, citations[1]!.end), second);
		assert.deepEqual(
			citations.map(({ label, quote, comment, messageId }) => ({ label, quote, comment, messageId })),
			[
				{ label: "为什么要先归一化", quote: "为什么要先归一化", comment: undefined, messageId: "tutor_1" },
				{ label: "我不懂这里 🤔", quote: "🎯 scale matters", comment: "我不懂这里 🤔", messageId: "tutor_1" },
			],
		);
	});

	it("leaves parts without quotes, and assistant text, unmarked", () => {
		const view = buildNativeView(chat([tutor, { id: "user_1", role: "user", content: "plain words", timestamp: 2 }]));
		assert.equal(userText(view).citations, undefined);
		for (const part of view.messages.filter((m) => m.role === "assistant").flatMap((m) => m.parts)) {
			assert.equal(part.citations, undefined);
		}
	});

	it("ignores a malformed citation link (it stays ordinary text)", () => {
		const view = buildNativeView(chat([tutor, { id: "user_1", role: "user", content: "see [Tutor quote](lh-citation://v1/x/y?text=hi)", timestamp: 2 }]));
		assert.equal(userText(view).citations, undefined);
	});
});

// A 1×1 PNG and a second, different image.
const PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==";
const GIF = "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7";
const sha = (data: string) => createHash("sha256").update(data).digest("hex");

const created: string[] = [];
after(() => {
	for (const id of created) {
		try { fs.unlinkSync(path.join(PATHS.chats, `${id}.json`)); } catch { /* gone */ }
	}
});

/** A learner message with an image, practice thinking with two, and a tool
 *  result carrying one in its content and details. */
function imageMessages(): LhMessage[] {
	return [
		{ id: "user_image", role: "user", content: [{ type: "text", text: "my drawing" }, { type: "image", data: PNG, mimeType: "image/png" }], timestamp: 1 },
		newThinkingMessage("problem-call", "working", [{ type: "image", data: PNG, mimeType: "image/png" }, { type: "image", data: GIF, mimeType: "image/gif" }]),
		{
			id: "asst_call", role: "assistant", content: [{ type: "toolCall", id: "call-q", name: "quiz", arguments: { question: "Q?", options: [{ label: "a" }], correctAnswer: "a" } }],
			stopReason: "toolUse", api: "faux", provider: "faux", model: "faux", usage, timestamp: 2,
		},
		{
			id: "result_q", role: "toolResult", toolCallId: "call-q", toolName: "quiz", isError: false, timestamp: 3,
			content: [{ type: "text", text: "answered" }, { type: "image", data: GIF, mimeType: "image/gif" }],
			details: { kind: "quiz", answers: ["a"], images: { answer: [{ type: "image", data: GIF, mimeType: "image/gif" }] } },
		},
	] as LhMessage[];
}

function savedChat(messages: LhMessage[]) {
	const chat = chatStore.createChat("Images fixture");
	created.push(chat.id);
	chatStore.saveMessages(chat.id, messages);
	return chatStore.getChat(chat.id)!;
}

function imagesIn(value: unknown, out: Record<string, unknown>[] = []): Record<string, unknown>[] {
	if (Array.isArray(value)) for (const item of value) imagesIn(item, out);
	else if (value && typeof value === "object") {
		if ((value as { type?: unknown }).type === "image") out.push(value as Record<string, unknown>);
		else for (const item of Object.values(value)) imagesIn(item, out);
	}
	return out;
}

describe("native submitted images", () => {
	it("replaces every inline image with a reference: no base64 left in the view", () => {
		const view = buildNativeView(savedChat(imageMessages()));
		const json = JSON.stringify(view);
		assert.equal(json.includes(PNG), false);
		assert.equal(json.includes(GIF), false);
		const images = imagesIn(view.messages);
		assert.ok(images.length >= 5, `found ${images.length}`);
		for (const image of images) {
			assert.deepEqual(Object.keys(image).sort(), ["mimeType", "ref", "type"]);
			assert.equal(image.ref, sha(image.mimeType === "image/png" ? PNG : GIF));
		}
	});

	it("serves an image's bytes from its own session, immutable", async () => {
		const chat = savedChat(imageMessages());
		const response = nativeImageResponse(chat.id, sha(PNG));
		assert.equal(response.status, 200);
		assert.equal(response.headers.get("content-type"), "image/png");
		assert.match(response.headers.get("cache-control") ?? "", /immutable/);
		assert.deepEqual(Buffer.from(await response.arrayBuffer()), Buffer.from(PNG, "base64"));
	});

	it("answers 404 for a malformed ref, an unknown one, another session's, and a non-image type", () => {
		const chat = savedChat(imageMessages());
		const other = savedChat([{ id: "u", role: "user", content: "no images", timestamp: 1 } as LhMessage]);
		assert.equal(nativeImageResponse(chat.id, "not-a-ref").status, 404);
		assert.equal(nativeImageResponse(chat.id, "0".repeat(64)).status, 404);
		assert.equal(nativeImageResponse(other.id, sha(PNG)).status, 404);
		assert.equal(nativeImageResponse("chat_missing", sha(PNG)).status, 404);
		const html = savedChat([{ id: "u", role: "user", content: [{ type: "image", data: "PGI+aGk8L2I+", mimeType: "text/html" }], timestamp: 1 } as LhMessage]);
		assert.equal(nativeImageResponse(html.id, sha("PGI+aGk8L2I+")).status, 404);
	});

	it("needs the token in cloud mode", () => {
		const saved = process.env.LH_REMOTE_TOKEN;
		process.env.LH_REMOTE_TOKEN = "t".repeat(43);
		try {
			const url = `https://lh.example.test/api/native/chats/chat_x/images/${sha(PNG)}`;
			assert.equal(proxy(new NextRequest(url, { headers: { host: "lh.example.test" } })).status, 401);
			assert.equal(proxy(new NextRequest(url, { headers: { host: "lh.example.test", authorization: `Bearer ${"t".repeat(43)}` } })).headers.get("x-middleware-next"), "1");
		} finally {
			if (saved === undefined) delete process.env.LH_REMOTE_TOKEN; else process.env.LH_REMOTE_TOKEN = saved;
		}
	});
});
