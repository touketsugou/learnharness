/**
 * Tutor quotes on the native view (iOS client, 2026-11-16): a learner's
 * `[Tutor quote](lh-citation://…)` links arrive as structured `citations`
 * on the text part (UTF-16 ranges into the displayed text), so the client
 * draws chips; the text itself stays as saved.
 */
import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { buildNativeView } from "../src/server/native-view.ts";
import { serializeCitation, type TutorCitation } from "../src/core/citations.ts";
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
