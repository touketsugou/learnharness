/**
 * NATIVE CLIENT CONTRACT (iOS client, owner 2026-11-07): the server-projected
 * session view the SwiftUI client renders. The server runs the same view
 * canon as the web client (projectView over the record + the live turn), so
 * grouping, dock and phase rules exist once, in TypeScript; Swift renders.
 *
 * Wire (GET /api/native/chats/:id/stream, SSE `data:` lines, then [DONE]):
 *   running turn: snapshot → patch* → settled
 *   no turn:      settled
 * `snapshot`/`settled` replace the whole view; `patch` carries the session
 * state, the full ordered message id list, and only the messages whose
 * content changed since the previous frame of the same stream.
 *
 * Learner-facing redaction: the pending question's correct answer /
 * commitment / explanation and an active problem's model solution never
 * appear in this view (dock or transcript parts) until they are answered
 * or concluded.
 *
 * Display text: math is normalized with the web's render-time functions
 * (prose: transformMathDelimiters; tool content such as questions, options,
 * explanations, problem statements and verdicts: repairMathForDisplay then
 * transformMathDelimiters), so clients render only $...$ and $$...$$.
 * Option `value`s are never rewritten — answers submit them verbatim.
 *
 * Fixtures for the Swift decoder: tests/fixtures/native/*.json
 * (scripts/export-native-fixtures.ts).
 */

import { Type, type Static } from "typebox";
import type { ChatSettings } from "./chat.ts";
import type { PlanTree } from "./plan.ts";
import type { QuizOption } from "../question-core.ts";

export const NATIVE_VIEW_VERSION = 1;

/** One rendered part — the web renderer's part vocabulary (LhViewPart). */
export interface NativeViewPart {
	type: string;
	id?: string;
	text?: string;
	state?: string;
	toolCallId?: string;
	input?: unknown;
	output?: unknown;
	errorText?: string;
	data?: unknown;
	[key: string]: unknown;
}

export interface NativeViewMessage {
	id: string;
	role: "user" | "assistant";
	parts: NativeViewPart[];
	metadata?: unknown;
}

export interface NativeQuestionDock {
	type: "question";
	toolCallId: string;
	/** Draft/reset identity (differs from toolCallId only for legacy duplicate ids). */
	key: string;
	/** The posing tool: probe | recall | quiz | explain | ask_user_question. */
	tool: string;
	kind: "quiz" | "ask" | "explain";
	questionType?: "predict" | "check";
	question: string;
	context?: string;
	mode: "single-select" | "multi-select" | "text";
	/** Display order (quiz options shuffled by toolCallId, same as the web dock). */
	options: QuizOption[];
	/** A teach-phase check waits behind the "Check your understanding" reveal. */
	needsReveal: boolean;
	confidenceStops: number[];
	defaultConfidenceIndex: number;
}

export interface NativeProblemDock {
	type: "problem";
	toolCallId: string;
	statement?: string;
	mode?: string;
}

/** Practice pause: nothing active, at least one problem posed — Next is available. */
export interface NativeBetweenProblemsDock {
	type: "between-problems";
}

export type NativeDock = NativeQuestionDock | NativeProblemDock | NativeBetweenProblemsDock;

export interface NativeMalformedQuestion {
	toolCallId: string;
	messageId: string;
	contentIndex: number;
	tool: string;
}

export interface NativePlan {
	tree: PlanTree;
	current: string | null;
	visited: string[];
}

export interface NativeFailure {
	message: string;
	/** A failed response with retryable input (the Retry button). */
	canRetry: boolean;
}

export interface NativeUsage {
	contextTokens: number | null;
	cost: number;
	unpriced: number;
	subscription?: number;
}

export interface NativeCoverage {
	totalMessages: number;
	coveredCount: number;
	uncoveredCount: number;
	coveredTokens: number;
	uncoveredTokens: number;
	running: boolean;
	lastFoldedAt: string | null;
}

export type NativeSessionStatus = "idle" | "running" | "compacting";

/** Everything but the transcript — the `patch` frame's state block. */
export interface NativeSessionState {
	version: typeof NATIVE_VIEW_VERSION;
	chatId: string;
	title: string;
	kind: "teach" | "practice";
	createdAt: string;
	updatedAt: string;
	/** Monotonic within one stream; 0 for a standalone snapshot. */
	revision: number;
	status: NativeSessionStatus;
	/** Teaching phase (probe → plan → teach); null for practice sessions. */
	phase: "probe" | "plan" | "teach" | null;
	/** What the running turn is doing right now ("Making a visual…"). */
	activity: string | null;
	dock: NativeDock | null;
	malformedQuestions: NativeMalformedQuestion[];
	plan: NativePlan | null;
	/** The record owes a reaction turn: an idle client sends `continue` (web parity). */
	needsContinuation: boolean;
	failure: NativeFailure | null;
	usage: NativeUsage;
	settings: ChatSettings | null;
	coverage: NativeCoverage | null;
}

export interface NativeSessionView extends NativeSessionState {
	messages: NativeViewMessage[];
}

export type NativeStreamFrame =
	| { type: "snapshot"; view: NativeSessionView }
	| { type: "patch"; state: NativeSessionState; order: string[]; messages: NativeViewMessage[] }
	| { type: "settled"; view: NativeSessionView };

/** Native answer body: POST /api/native/chats/:id/answer. */
export interface NativeAnswerBody {
	toolCallId: string;
	request: {
		dontKnow?: boolean;
		values?: string[];
		other?: string;
		text?: string;
		thinking?: string;
		readingThinking?: string;
		confidence?: number;
	};
}

/** Upload result: POST /api/native/uploads → one entry per file, in order. */
export interface NativeUploadResult {
	files: Array<{ name: string; path: string; bytes: number }>;
}

// ─── schemas (fixture/contract checks) ──────────────────────────────────────

const PartSchema = Type.Object({ type: Type.String() }, { additionalProperties: true });
const MessageSchema = Type.Object({
	id: Type.String(),
	role: Type.Union([Type.Literal("user"), Type.Literal("assistant")]),
	parts: Type.Array(PartSchema),
	metadata: Type.Optional(Type.Unknown()),
});
const OptionSchema = Type.Object({ label: Type.String(), value: Type.String(), description: Type.Optional(Type.String()) });
const DockSchema = Type.Union([
	Type.Object({
		type: Type.Literal("question"),
		toolCallId: Type.String(),
		key: Type.String(),
		tool: Type.String(),
		kind: Type.Union([Type.Literal("quiz"), Type.Literal("ask"), Type.Literal("explain")]),
		questionType: Type.Optional(Type.Union([Type.Literal("predict"), Type.Literal("check")])),
		question: Type.String(),
		context: Type.Optional(Type.String()),
		mode: Type.Union([Type.Literal("single-select"), Type.Literal("multi-select"), Type.Literal("text")]),
		options: Type.Array(OptionSchema),
		needsReveal: Type.Boolean(),
		confidenceStops: Type.Array(Type.Number()),
		defaultConfidenceIndex: Type.Number(),
	}, { additionalProperties: false }),
	Type.Object({
		type: Type.Literal("problem"),
		toolCallId: Type.String(),
		statement: Type.Optional(Type.String()),
		mode: Type.Optional(Type.String()),
	}, { additionalProperties: false }),
	Type.Object({ type: Type.Literal("between-problems") }, { additionalProperties: false }),
]);
const StateProperties = {
	version: Type.Literal(NATIVE_VIEW_VERSION),
	chatId: Type.String(),
	title: Type.String(),
	kind: Type.Union([Type.Literal("teach"), Type.Literal("practice")]),
	createdAt: Type.String(),
	updatedAt: Type.String(),
	revision: Type.Number(),
	status: Type.Union([Type.Literal("idle"), Type.Literal("running"), Type.Literal("compacting")]),
	phase: Type.Union([Type.Literal("probe"), Type.Literal("plan"), Type.Literal("teach"), Type.Null()]),
	activity: Type.Union([Type.String(), Type.Null()]),
	dock: Type.Union([DockSchema, Type.Null()]),
	malformedQuestions: Type.Array(Type.Object({ toolCallId: Type.String(), messageId: Type.String(), contentIndex: Type.Number(), tool: Type.String() })),
	plan: Type.Union([
		Type.Object({ tree: Type.Object({ nodes: Type.Array(Type.Unknown()), edges: Type.Array(Type.Unknown()), version: Type.Number() }), current: Type.Union([Type.String(), Type.Null()]), visited: Type.Array(Type.String()) }),
		Type.Null(),
	]),
	needsContinuation: Type.Boolean(),
	failure: Type.Union([Type.Object({ message: Type.String(), canRetry: Type.Boolean() }), Type.Null()]),
	usage: Type.Object({ contextTokens: Type.Union([Type.Number(), Type.Null()]), cost: Type.Number(), unpriced: Type.Number(), subscription: Type.Optional(Type.Number()) }),
	settings: Type.Union([Type.Object({}, { additionalProperties: true }), Type.Null()]),
	coverage: Type.Union([Type.Object({}, { additionalProperties: true }), Type.Null()]),
};
export const NativeSessionStateSchema = Type.Object(StateProperties, { additionalProperties: false });
export const NativeSessionViewSchema = Type.Object({ ...StateProperties, messages: Type.Array(MessageSchema) }, { additionalProperties: false });
export const NativeStreamFrameSchema = Type.Union([
	Type.Object({ type: Type.Literal("snapshot"), view: NativeSessionViewSchema }),
	Type.Object({ type: Type.Literal("patch"), state: NativeSessionStateSchema, order: Type.Array(Type.String()), messages: Type.Array(MessageSchema) }),
	Type.Object({ type: Type.Literal("settled"), view: NativeSessionViewSchema }),
]);
export type NativeStreamFrameStatic = Static<typeof NativeStreamFrameSchema>;
