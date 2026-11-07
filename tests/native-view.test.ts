/**
 * Native client surface (iOS client, 2026-11-07): the server-projected view
 * (web canon, redacted), server-graded answers through the ordinary answer
 * path, the turn-scoped projected stream, and learner uploads. Scripted pi
 * engine (faux provider) — zero tokens, no Next server.
 */
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { after, describe, it } from "node:test";
import { createFauxCore, fauxAssistantMessage, fauxText, fauxThinking, fauxToolCall, type FauxResponseStep } from "@earendil-works/pi-ai";
import { Value } from "typebox/value";
import { PATHS } from "../config.ts";
import { createPracticeAgent, createTeacherAgent } from "../src/agent/teacher-agent.ts";
import type { PiEngine } from "../src/agent/models.ts";
import { handleChatRequest } from "../src/server/chat-handler.ts";
import { buildNativeView, nativeAnswerResponse, nativeStreamResponse, NativeFrameDiffer } from "../src/server/native-view.ts";
import { nativeUploadResponse, safeUploadName } from "../src/server/native-uploads.ts";
import { runningTurn } from "../src/server/turn-runs.ts";
import { chatStore } from "../src/store/chats.ts";
import { NativeSessionViewSchema, NativeStreamFrameSchema, type NativeQuestionDock, type NativeStreamFrame } from "../src/core/contracts/native.ts";
import { answerInputFromRequest, ChatInputError } from "../src/core/input-events.ts";
import { normalizeOptions, seededRandom, shuffleOptions } from "../src/core/question-core.ts";

process.env.OPENROUTER_API_KEY ??= "test-key-presence-gate";

const QUIZ_INPUT = {
	question: "Which planet is closest to the sun?",
	options: [{ label: "Venus" }, { label: "Mercury" }, { label: "Mars" }],
	correctAnswer: "Mercury",
	explanation: "Mercury is the innermost planet.",
	type: "check",
	nodeId: "planet-order",
};

function teacher(steps: FauxResponseStep[]): PiEngine {
	const faux = createFauxCore({});
	faux.setResponses(steps);
	return { model: faux.getModel(), streamFn: faux.streamSimple };
}

function factory(engine: PiEngine): Parameters<typeof handleChatRequest>[1] {
	return (opts) => createTeacherAgent(undefined, { engine, messages: opts.messages });
}

const created: string[] = [];
after(() => {
	for (const id of created) {
		try { fs.unlinkSync(path.join(PATHS.chats, `${id}.json`)); } catch { /* gone */ }
	}
});

function configuredChat(title: string, kind?: "practice") {
	const chat = chatStore.createChat(title, kind);
	created.push(chat.id);
	chatStore.saveSettings(chat.id, { model: { provider: "openrouter", id: "z-ai/glm-5.3-flash" } });
	chatStore.saveTree(chat.id, { nodes: [{ id: "planet-order", title: "Planet order" }], edges: [], version: 1 });
	return chat;
}

function post(chatId: string, input: unknown): Request {
	return new Request("http://test/api/chat", {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify({ chatId, input }),
	});
}

async function runTurn(chatId: string, input: unknown, engine: PiEngine, build = factory(engine)): Promise<void> {
	const ack = await handleChatRequest(post(chatId, input), build);
	assert.equal(ack.status, 200, await ack.clone().text());
	const handle = runningTurn(chatId);
	if (handle) await new Response(handle.subscribe()).text();
}

function framesOf(body: string): Array<NativeStreamFrame | "[DONE]"> {
	return body.split("\n").filter((l) => l.startsWith("data: ")).map((l) => {
		const data = l.slice(6);
		return data === "[DONE]" ? "[DONE]" : (JSON.parse(data) as NativeStreamFrame);
	});
}

function answerPost(chatId: string, body: unknown): Request {
	return new Request(`http://test/api/native/chats/${chatId}/answer`, {
		method: "POST",
		headers: { "Content-Type": "application/json" },
		body: JSON.stringify(body),
	});
}

describe("native view projection", () => {
	it("projects a pending quiz into a redacted question dock in the web dock's order", async () => {
		const chat = configuredChat("Native: solar system");
		await runTurn(chat.id, { type: "text", text: "teach me the solar system" }, teacher([
			() => fauxAssistantMessage([fauxThinking("Probe first."), fauxToolCall("quiz", QUIZ_INPUT, { id: "call-1" })], { stopReason: "toolUse" }),
		]));
		const view = buildNativeView(chatStore.getChat(chat.id)!);
		assert(Value.Check(NativeSessionViewSchema, view), JSON.stringify([...Value.Errors(NativeSessionViewSchema, view)].slice(0, 3)));
		assert.equal(view.status, "idle");
		assert.equal(view.kind, "teach");
		const dock = view.dock as NativeQuestionDock;
		assert.equal(dock.type, "question");
		assert.equal(dock.toolCallId, "call-1");
		assert.equal(dock.kind, "quiz");
		assert.equal(dock.mode, "single-select");
		const expected = shuffleOptions(normalizeOptions(QUIZ_INPUT.options), seededRandom("call-1")).map((o) => o.value);
		assert.deepEqual(dock.options.map((o) => o.value), expected);
		const json = JSON.stringify(view);
		assert(!json.includes("correctAnswer"), "no correct answer anywhere in the learner view");
		assert(!json.includes("innermost"), "no explanation before answering");
		assert.equal(view.needsContinuation, false);
		assert.deepEqual(view.messages.map((m) => m.role), ["user", "assistant"]);

		// ── Server-graded answer through the ordinary answer path ──
		const bad = await nativeAnswerResponse(chat.id, answerPost(chat.id, { toolCallId: "call-1", request: { values: ["Pluto"], confidence: 70 } }));
		assert.equal(bad.status, 400);
		const noConfidence = await nativeAnswerResponse(chat.id, answerPost(chat.id, { toolCallId: "call-1", request: { values: ["Mercury"] } }));
		assert.equal(noConfidence.status, 400);
		const wrongCall = await nativeAnswerResponse(chat.id, answerPost(chat.id, { toolCallId: "call-9", request: { dontKnow: true } }));
		assert.equal(wrongCall.status, 400);

		const engine = teacher([() => fauxAssistantMessage([fauxText("Right — Mercury it is.")])]);
		const ack = await nativeAnswerResponse(chat.id, answerPost(chat.id, { toolCallId: "call-1", request: { values: ["Mercury"], confidence: 70, thinking: " closest orbit " } }), factory(engine));
		assert.equal(ack.status, 200, await ack.clone().text());
		const handle = runningTurn(chat.id);
		if (handle) await new Response(handle.subscribe()).text();
		const saved = chatStore.getChat(chat.id)!;
		const result = saved.messages.find((m) => m.role === "toolResult" && m.toolCallId === "call-1");
		assert(result && result.role === "toolResult");
		const details = result.details as { correct?: boolean; confidence?: number; thinking?: string; options?: Array<{ label: string }> };
		assert.equal(details.correct, true);
		assert.equal(details.confidence, 70);
		assert.equal(details.thinking, "closest orbit");
		assert.deepEqual(details.options?.map((o) => o.label), expected, "the answer snapshots the native display order");

		const after = buildNativeView(saved);
		assert.equal(after.dock, null);
		assert(JSON.stringify(after.messages).includes("Mercury it is"));
	});

	it("rejects empty and over-selected answers before any turn", () => {
		const record = [
			{ id: "u1", role: "user", content: "hi", timestamp: 0 },
			{ id: "a1", role: "assistant", content: [{ type: "toolCall", id: "q1", name: "quiz", arguments: QUIZ_INPUT }], stopReason: "toolUse", api: "x", provider: "x", model: "x", usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, timestamp: 0 },
		] as never;
		assert.throws(() => answerInputFromRequest(record, "q1", {}), ChatInputError);
		assert.throws(() => answerInputFromRequest(record, "q1", { values: ["Venus", "Mars"], confidence: 50 }), ChatInputError);
		const dontKnow = answerInputFromRequest(record, "q1", { dontKnow: true });
		assert.equal(dontKnow.answer.dontKnow, true);
		assert.equal(dontKnow.answer.correct, false);
		assert.equal(dontKnow.answer.confidence, undefined);
	});

	it("never shows a posed problem's model solution", async () => {
		const chat = configuredChat("Native: practice", "practice");
		const problem = { statement: "Name the innermost planet.", mode: "recall", target: ["planet-order"], modelSolution: "SECRET-SOLUTION Mercury" };
		const engine = teacher([
			() => fauxAssistantMessage([fauxToolCall("problem", problem, { id: "p-1" })], { stopReason: "toolUse" }),
		]);
		await runTurn(chat.id, { type: "text", text: "practice" }, engine,
			(opts) => createPracticeAgent({ chatId: chat.id, chatStore }, { engine, messages: opts.messages }));
		const view = buildNativeView(chatStore.getChat(chat.id)!);
		assert.equal(view.kind, "practice");
		assert.equal(view.phase, null);
		assert.deepEqual(view.dock, { type: "problem", toolCallId: "p-1", statement: problem.statement, mode: "recall" });
		assert(!JSON.stringify(view).includes("SECRET-SOLUTION"));
	});
});

describe("native stream", () => {
	it("answers an idle session with one settled frame", async () => {
		const chat = configuredChat("Native: idle");
		const frames = framesOf(await nativeStreamResponse(chat.id).text());
		assert.equal(frames.length, 2);
		assert.equal((frames[0] as NativeStreamFrame).type, "settled");
		assert.equal(frames[1], "[DONE]");
		assert.equal(nativeStreamResponse("chat_missing").status, 404);
	});

	it("streams snapshot → patches → settled for a running turn", async () => {
		const chat = configuredChat("Native: live");
		let release!: () => void;
		const gate = new Promise<void>((resolve) => { release = resolve; });
		const engine = teacher([
			async () => {
				await gate;
				return fauxAssistantMessage([fauxText("Gated reply.")]);
			},
		]);
		const ack = await handleChatRequest(post(chat.id, { type: "text", text: "hello" }), factory(engine));
		assert.equal(ack.status, 200);
		const response = nativeStreamResponse(chat.id, { coalesceMs: 1 });
		const reader = response.body!.getReader();
		const decoder = new TextDecoder();
		let text = "";
		while (!text.includes("\n\n")) text += decoder.decode((await reader.read()).value!, { stream: true });
		const first = framesOf(text)[0] as NativeStreamFrame;
		assert.equal(first.type, "snapshot");
		assert(first.type === "snapshot" && first.view.status === "running");
		release();
		for (;;) {
			const { done, value } = await reader.read();
			if (done) break;
			text += decoder.decode(value, { stream: true });
		}
		const frames = framesOf(text);
		assert.equal(frames.at(-1), "[DONE]");
		const settled = frames.at(-2) as NativeStreamFrame;
		assert.equal(settled.type, "settled");
		assert(settled.type === "settled" && settled.view.status === "idle");
		assert(JSON.stringify(settled).includes("Gated reply."));
		for (const frame of frames.slice(0, -1)) assert(Value.Check(NativeStreamFrameSchema, frame), JSON.stringify(frame).slice(0, 200));
		const revisions = frames.slice(0, -1).map((f) => {
			const frame = f as NativeStreamFrame;
			return frame.type === "patch" ? frame.state.revision : frame.view.revision;
		});
		assert.deepEqual(revisions, [...revisions].sort((a, b) => a - b), "revisions are monotonic");
	});

	it("patches only changed messages and skips no-op frames", () => {
		const differ = new NativeFrameDiffer();
		const base = buildNativeView({ id: "c", title: "t", createdAt: "x", updatedAt: "x", messages: [
			{ id: "u1", role: "user", content: "one", timestamp: 0 },
			{ id: "u2", role: "user", content: "two", timestamp: 0 },
		] } as never);
		differ.snapshot(base, "snapshot");
		assert.equal(differ.patch(base), null);
		const changed = { ...base, messages: [base.messages[0]!, { ...base.messages[1]!, parts: [{ type: "text", text: "two!" }] }] };
		const patch = differ.patch(changed);
		assert(patch && patch.type === "patch");
		assert.deepEqual(patch.order, ["u1", "u2"]);
		assert.deepEqual(patch.messages.map((m) => m.id), ["u2"]);
	});
});

describe("native uploads", () => {
	const root = fs.mkdtempSync(path.join(os.tmpdir(), "lh-uploads-"));

	function upload(files: File[], headers: Record<string, string> = {}): Request {
		const form = new FormData();
		for (const file of files) form.append("files", file);
		return new Request("http://test/api/native/uploads", { method: "POST", body: form, headers });
	}

	it("stores files under the month folder with safe names and returns server paths", async () => {
		const response = await nativeUploadResponse(upload([new File(["hello"], "../../etc/passwd"), new File([new Uint8Array([1, 2, 3])], "photo.jpg")]), { root, now: new Date("2026-11-07T00:00:00Z") });
		assert.equal(response.status, 201);
		const body = (await response.json()) as { files: Array<{ name: string; path: string; bytes: number }> };
		assert.deepEqual(body.files.map((f) => f.name), ["passwd", "photo.jpg"]);
		for (const file of body.files) {
			assert(file.path.startsWith(path.join(root, "2026-11") + path.sep), file.path);
			assert.equal(fs.statSync(file.path).size, file.bytes);
			assert.equal(fs.statSync(file.path).mode & 0o777, 0o600);
		}
	});

	it("refuses empty and oversized uploads", async () => {
		assert.equal((await nativeUploadResponse(upload([]), { root })).status, 400);
		const big = new Request("http://test/api/native/uploads", { method: "POST", headers: { "content-length": String(30 * 1024 * 1024), "content-type": "multipart/form-data; boundary=x" }, body: "x" });
		assert.equal((await nativeUploadResponse(big, { root })).status, 413);
	});

	it("sanitizes names", () => {
		assert.equal(safeUploadName("a/b\\c.txt"), "c.txt");
		assert.equal(safeUploadName("..."), "upload");
		assert.equal(safeUploadName("x\u0000y:z.md"), "xyz.md");
		assert.equal(safeUploadName(`${"n".repeat(300)}.pdf`).length, 120);
	});
});
