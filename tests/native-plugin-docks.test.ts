/**
 * Plugin questions and problems on the native view (iOS client, 2026-11-16).
 * Only the web app can answer them (their editors are plugin code), so the
 * native dock carries the question text and the exact dismissal authority,
 * and a plugin problem's model solution never reaches the client.
 */
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { after, describe, it } from "node:test";
import { Value } from "typebox/value";
import { PATHS } from "../config.ts";
import { buildNativeView } from "../src/server/native-view.ts";
import { chatStore } from "../src/store/chats.ts";
import { NativeSessionViewSchema, type NativePluginQuestionDock } from "../src/core/contracts/native.ts";
import { newUserMessage, type LhMessage } from "../src/core/native-messages.ts";
import type { PluginQuestionSnapshot } from "../src/core/plugin-questions.ts";

const dismissRoute = await import("../app/api/chats/[id]/dismiss/route.ts");

const created: string[] = [];
after(() => {
	for (const id of created) {
		try { fs.unlinkSync(path.join(PATHS.chats, `${id}.json`)); } catch { /* gone */ }
	}
});

const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };

function chatWith(messages: LhMessage[], kind?: "practice") {
	const chat = chatStore.createChat("Plugin dock fixture", kind);
	created.push(chat.id);
	chatStore.saveMessages(chat.id, messages);
	return chatStore.getChat(chat.id)!;
}

/** A posed plugin question at content index 1, after a reasoning block. */
function pose(id = "pose", callId = "call_0"): LhMessage & { role: "assistant" } {
	const snapshot: PluginQuestionSnapshot = {
		protocolVersion: 1, pluginId: "fixture", typeId: "code", label: "Code question", variant: "probe",
		questionId: `question-${id}`, occurrence: { messageId: id, contentIndex: 1, toolCallId: callId, toolName: "fixture_code" }, contractVersion: 1,
		input: { question: "Write $x^2$ as code.", payload: { reference: "PAYLOAD" } },
		questionSchema: { type: "object", properties: { reference: { type: "string" } }, required: ["reference"], additionalProperties: false },
		answerSchema: { type: "string" },
		showThinking: true, requiresAnswerRefinement: false,
	};
	return {
		id, role: "assistant", content: [
			{ type: "thinking", thinking: "reasoning", thinkingSignature: "sig" },
			{ type: "toolCall", id: callId, name: "fixture_code", arguments: { question: "Write $x^2$ as code.", payload: { reference: "PAYLOAD" } } },
		], lhQuestions: { "1": snapshot },
		stopReason: "toolUse", timestamp: 1, api: "openai-completions", provider: "fixture", model: "fixture", usage,
	};
}

describe("native plugin question dock", () => {
	it("docks a pending plugin question with its text, label and dismissal authority", () => {
		const view = buildNativeView(chatWith([newUserMessage("Start"), pose()]));
		assert.deepEqual(view.dock, {
			type: "plugin-question",
			toolCallId: "call_0",
			occurrence: { messageId: "pose", contentIndex: 1, toolCallId: "call_0", toolName: "fixture_code" },
			questionId: "question-pose",
			label: "Code question",
			question: "Write $x^2$ as code.",
			available: true,
		});
		assert.ok(Value.Check(NativeSessionViewSchema, view), JSON.stringify([...Value.Errors(NativeSessionViewSchema, view)].slice(0, 3)));
	});

	it("dismissing with the dock's occurrence and question id clears it", async () => {
		const chat = chatWith([newUserMessage("Start"), pose()]);
		const dock = buildNativeView(chat).dock as NativePluginQuestionDock;
		const response = await dismissRoute.POST(
			new Request(`http://test/api/chats/${chat.id}/dismiss`, {
				method: "POST",
				headers: { "Content-Type": "application/json" },
				body: JSON.stringify({ input: { type: "dismiss-plugin-question", occurrence: dock.occurrence, questionId: dock.questionId } }),
			}),
			{ params: Promise.resolve({ id: chat.id }) },
		);
		assert.equal(response.status, 200, await response.clone().text());
		assert.equal(buildNativeView(chatStore.getChat(chat.id)!).dock, null);
	});

	it("docks an unreadable plugin question without text, still dismissable", () => {
		const unreadable = pose();
		unreadable.lhQuestions = { "1": { protocolVersion: 99 } } as never;
		const view = buildNativeView(chatWith([newUserMessage("Start"), unreadable]));
		const dock = view.dock as NativePluginQuestionDock;
		assert.equal(dock.type, "plugin-question");
		assert.equal(dock.available, false);
		assert.equal(dock.question, undefined);
		assert.equal(dock.label, undefined);
		assert.deepEqual(dock.occurrence, { messageId: "pose", contentIndex: 1, toolCallId: "call_0", toolName: "fixture_code" });
		assert.ok(Value.Check(NativeSessionViewSchema, view));
	});
});

describe("native plugin problem dock", () => {
	const toolName = "problem_code";
	const input = { statement: "Implement $f$", mode: "composition", modelSolution: "THE-COMMITTED-SOLUTION", payload: {} };
	const occurrence = { messageId: "pose-problem", contentIndex: 0, toolCallId: "problem-call", toolName };
	const snapshot = {
		protocolVersion: 1, problemId: "problem-1", pluginId: "problem-fixture", typeId: "code", label: "Code", contractVersion: 1,
		input, problemSchema: { type: "object", properties: {} }, submissionSchema: { type: "string", minLength: 1 },
		requiresSubmissionRefinement: false, requiresProcessing: true,
	};
	const messages = [
		newUserMessage("Start"),
		{
			id: occurrence.messageId, role: "assistant", content: [{ type: "toolCall", id: occurrence.toolCallId, name: toolName, arguments: input }],
			stopReason: "toolUse", timestamp: 1, api: "openai-completions", provider: "fixture", model: "fixture", usage,
		},
		{
			id: "pose-problem-ack", role: "toolResult", toolCallId: occurrence.toolCallId, toolName,
			content: [{ type: "text", text: "Problem posed" }], details: { pluginProblem: snapshot }, isError: false, timestamp: 2,
		},
	] as LhMessage[];

	it("docks as a problem with the plugin's label", () => {
		const view = buildNativeView(chatWith(messages, "practice"));
		assert.deepEqual(view.dock, {
			type: "problem",
			toolCallId: "problem-call",
			statement: "Implement $f$",
			mode: "composition",
			plugin: { label: "Code" },
		});
		assert.ok(Value.Check(NativeSessionViewSchema, view), JSON.stringify([...Value.Errors(NativeSessionViewSchema, view)].slice(0, 3)));
	});

	it("never exposes the model solution anywhere in the view", () => {
		const view = buildNativeView(chatWith(messages, "practice"));
		assert.equal(JSON.stringify(view).includes("THE-COMMITTED-SOLUTION"), false);
		assert.equal(JSON.stringify(view).includes("modelSolution"), false);
	});
});
