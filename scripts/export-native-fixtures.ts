/**
 * Native-contract fixtures (iOS client, 2026-11-07): the server-projected
 * views and stream frames the Swift decoder tests read, generated from the
 * golden data dir (real records) plus synthetic sessions: a pending quiz,
 * a plugin's question, a plugin's practice problem and tutor quotes.
 *
 *   npx tsx scripts/export-native-fixtures.ts     # rewrite tests/fixtures/native/
 *
 * tests/native-fixtures.test.ts regenerates in memory and fails when the
 * committed files drift (THE FIXTURE LAW: an intentional contract change
 * updates the fixtures in the same commit).
 */
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const GOLDEN = path.join(ROOT, "tests", "fixtures", "golden-data");
export const NATIVE_FIXTURES_DIR = path.join(ROOT, "tests", "fixtures", "native");

const QUIZ = {
	question: "Which planet is closest to the sun?",
	options: [{ label: "Venus" }, { label: "Mercury" }, { label: "Mars" }],
	correctAnswer: "Mercury",
	explanation: "Mercury is the innermost planet.",
	type: "check",
};

const USAGE = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };

function assistant(id: string, content: unknown[], stopReason = "stop") {
	return { id, role: "assistant", content, stopReason, api: "faux", provider: "faux", model: "faux", usage: USAGE, timestamp: 1_790_000_000_000 };
}

/** Every fixture file name → its JSON value. Points LH_DATA_DIR at a private
 *  copy of the golden data before any store module loads. */
export async function generateNativeFixtures(): Promise<Record<string, unknown>> {
	if (!process.env.LH_DATA_DIR?.includes("lh-native-fixtures-")) {
		const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "lh-native-fixtures-"));
		fs.cpSync(GOLDEN, tmp, { recursive: true });
		process.env.LH_DATA_DIR = tmp;
	}
	const { chatStore } = await import("../src/store/chats.ts");
	const { buildNativeView, NativeFrameDiffer } = await import("../src/server/native-view.ts");
	const { answerInputFromRequest } = await import("../src/core/input-events.ts");
	const { newAnswerResult } = await import("../src/core/native-messages.ts");

	const out: Record<string, unknown> = {};
	const chatIds = fs.readdirSync(path.join(GOLDEN, "chats")).filter((f) => f.endsWith(".json")).map((f) => f.slice(0, -5)).sort();
	for (const id of chatIds) {
		const chat = chatStore.getChat(id);
		if (!chat) throw new Error(`golden chat ${id} did not load`);
		out[`${id}.view.json`] = buildNativeView(chat);
	}

	const pending = {
		id: "chat_native_fixture",
		title: "Fixture: solar system",
		createdAt: "2026-11-07T00:00:00.000Z",
		updatedAt: "2026-11-07T00:00:00.000Z",
		messages: [
			{ id: "msg_user_1", role: "user", content: "teach me the solar system", timestamp: 1_790_000_000_000 },
			assistant("msg_asst_1", [{ type: "thinking", thinking: "Probe first." }, { type: "text", text: "Let's check one thing." }, { type: "toolCall", id: "call-1", name: "quiz", arguments: QUIZ }], "toolUse"),
		],
	} as never as Parameters<typeof buildNativeView>[0];
	const pendingView = buildNativeView(pending);
	out["pending-quiz.view.json"] = pendingView;

	const answer = answerInputFromRequest(pending.messages, "call-1", { values: ["Mercury"], confidence: 70 });
	const answeredResult = { ...newAnswerResult("call-1", "quiz", { ...answer.answer, answeredAt: "2026-11-07T00:00:01.000Z" }), id: "msg_result_1", timestamp: 1_790_000_001_000 };
	const answered = {
		...pending,
		messages: [...pending.messages, answeredResult, assistant("msg_asst_2", [{ type: "text", text: "Right — Mercury it is." }])],
	} as never as Parameters<typeof buildNativeView>[0];
	const answeredView = buildNativeView(answered);
	const differ = new NativeFrameDiffer();
	out["stream-frames.json"] = [
		differ.snapshot(pendingView, "snapshot"),
		differ.patch(answeredView),
		differ.snapshot(answeredView, "settled"),
	];

	// A plugin's question, answered only in the web app (iOS: dismiss or open).
	const pluginOccurrence = { messageId: "msg_asst_plugin", contentIndex: 1, toolCallId: "call-plugin", toolName: "fixture_code" };
	const pluginQuestion = {
		id: "chat_native_plugin_question",
		title: "Fixture: plugin question",
		createdAt: "2026-11-16T00:00:00.000Z",
		updatedAt: "2026-11-16T00:00:00.000Z",
		messages: [
			{ id: "msg_user_plugin", role: "user", content: "quiz me on loops", timestamp: 1_790_000_000_000 },
			{
				...assistant("msg_asst_plugin", [
					{ type: "thinking", thinking: "A coding check." },
					{ type: "toolCall", id: "call-plugin", name: "fixture_code", arguments: { question: "Write a loop that sums $1..n$.", payload: {} } },
				], "toolUse"),
				lhQuestions: { "1": {
					protocolVersion: 1, pluginId: "fixture", typeId: "code", label: "Code question", variant: "probe",
					questionId: "question-plugin", occurrence: pluginOccurrence, contractVersion: 1,
					input: { question: "Write a loop that sums $1..n$.", payload: {} },
					questionSchema: { type: "object", properties: {}, additionalProperties: false },
					answerSchema: { type: "string" },
					showThinking: true, requiresAnswerRefinement: false,
				} },
			},
		],
	} as never as Parameters<typeof buildNativeView>[0];
	out["plugin-question.view.json"] = buildNativeView(pluginQuestion);

	// A plugin's practice problem: discard here, submit in the web app.
	const problemInput = { statement: "Implement $f(n) = n^2$.", mode: "composition", modelSolution: "return n * n", payload: {} };
	const pluginProblem = {
		id: "chat_native_plugin_problem",
		title: "Fixture: plugin problem",
		kind: "practice",
		createdAt: "2026-11-16T00:00:00.000Z",
		updatedAt: "2026-11-16T00:00:00.000Z",
		messages: [
			{ id: "msg_user_problem", role: "user", content: "practice squares", timestamp: 1_790_000_000_000 },
			assistant("msg_asst_problem", [{ type: "toolCall", id: "call-problem", name: "problem_code", arguments: problemInput }], "toolUse"),
			{
				id: "msg_problem_ack", role: "toolResult", toolCallId: "call-problem", toolName: "problem_code",
				content: [{ type: "text", text: "Problem posed" }], isError: false, timestamp: 1_790_000_000_500,
				details: { pluginProblem: {
					protocolVersion: 1, problemId: "problem-fixture", pluginId: "fixture", typeId: "code", label: "Code", contractVersion: 1,
					input: problemInput, problemSchema: { type: "object", properties: {} }, submissionSchema: { type: "string", minLength: 1 },
					requiresSubmissionRefinement: false, requiresProcessing: true,
				} },
			},
		],
	} as never as Parameters<typeof buildNativeView>[0];
	out["plugin-problem.view.json"] = buildNativeView(pluginProblem);

	// Tutor quotes in a learner message (CJK and emoji: UTF-16 ranges).
	const { serializeCitation } = await import("../src/core/citations.ts");
	const quote = (text: string, comment?: string) => serializeCitation({
		version: 1, chatId: "chat_native_citations", messageId: "msg_tutor_quoted", text,
		start: 0, end: text.length, prefix: "", suffix: "", ...(comment ? { comment } : {}),
	});
	const citations = {
		id: "chat_native_citations",
		title: "Fixture: tutor quotes",
		createdAt: "2026-11-16T00:00:00.000Z",
		updatedAt: "2026-11-16T00:00:00.000Z",
		messages: [
			{ id: "msg_user_start", role: "user", content: "teach me normalization", timestamp: 1_790_000_000_000 },
			assistant("msg_tutor_quoted", [{ type: "text", text: "为什么要先归一化？Because 🎯 scale matters." }]),
			{ id: "msg_user_quoting", role: "user", content: `这里没懂：${quote("为什么要先归一化")} 还有 😀 ${quote("🎯 scale matters", "我不懂这里 🤔")}`, timestamp: 1_790_000_002_000 },
		],
	} as never as Parameters<typeof buildNativeView>[0];
	out["citations.view.json"] = buildNativeView(citations);
	return JSON.parse(JSON.stringify(out)) as Record<string, unknown>;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
	const fixtures = await generateNativeFixtures();
	fs.mkdirSync(NATIVE_FIXTURES_DIR, { recursive: true });
	for (const [name, value] of Object.entries(fixtures)) {
		fs.writeFileSync(path.join(NATIVE_FIXTURES_DIR, name), `${JSON.stringify(value, null, "\t")}\n`);
	}
	console.log(`wrote ${Object.keys(fixtures).length} fixtures to ${path.relative(ROOT, NATIVE_FIXTURES_DIR)}`);
}
