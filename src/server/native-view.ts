/**
 * THE NATIVE VIEW (iOS client, owner 2026-11-07): the session view the
 * SwiftUI client renders, projected SERVER-side with the web client's own
 * canon — projectView over the record + the live turn (core/live-turn.ts
 * merges the running turn's events exactly as the browser does), the
 * native pending-question / active-problem folds, phase, plan and
 * continuation rules. Swift renders and submits; it never re-derives.
 *
 * Contract and wire: src/core/contracts/native.ts.
 */

import type { ChatRecord } from "../core/contracts/chat.ts";
import {
	CONFIDENCE_STOPS,
	ChatInputError,
	DEFAULT_CONFIDENCE_INDEX,
	NATIVE_VIEW_VERSION,
	QUESTION_TOOLS,
	activeProblemOf,
	answerInputFromRequest,
	applyLiveEvent,
	derivePlanStatuses,
	emptyLiveTurnBuffer,
	endsInFailedTurn,
	failedResponseAtEnd,
	findPendingToolCall,
	latestPlanTree,
	liveEventActed,
	liveTurnState,
	malformedQuestionsOf,
	measuredContextTokens,
	needsContinuation,
	parseAnswerRequest,
	pendingQuestionOf,
	phaseAt3,
	projectView,
	questionDataFromCall,
	questionNeedsReveal,
	repairMathForDisplay,
	streamingToolActivity,
	subscribe as subscribeServerEvents,
	toClientQuestion,
	toolQuestionKind,
	transformMathDelimiters,
	type LhMessage,
	type LhViewMessage,
	type LhViewPart,
	type LiveTurnBuffer,
	type NativeDock,
	type NativeSessionState,
	type NativeSessionView,
	type NativeStreamFrame,
	type NativeViewMessage,
} from "../core/index.ts";
import { handleChatInput } from "./chat-handler.ts";
import { getChat, sessionCoverage } from "./chats.ts";
import { compactionInFlight } from "./compaction.ts";
import { sessionCost } from "./pricing.ts";
import { isTurnRunning } from "./turn-liveness.ts";
import { runningTurn, turnFailure } from "./turn-runs.ts";

/** The live layer of one native stream: the shared reducer's buffer plus the
 *  web model's failure/usage bookkeeping for the same turn. */
export interface NativeLiveLayer {
	buffer: LiveTurnBuffer;
	loopError: string | null;
	liveFailureId: string | null;
	incompleteUsageIds: Set<string>;
}

export function emptyNativeLiveLayer(): NativeLiveLayer {
	return { buffer: emptyLiveTurnBuffer(), loopError: null, liveFailureId: null, incompleteUsageIds: new Set() };
}

// Live ids carry the web client's local prefix: the native question folds
// (pendingQuestionOf's placeholder filter) key on it.
let mintSeq = 0;
function mintLiveId(): string {
	return `c_${Date.now().toString(36)}_n${(mintSeq++).toString(36)}`;
}

/** Apply one turn wire event to a live layer. Returns whether it did view work. */
export function applyNativeLiveEvent(layer: NativeLiveLayer, record: readonly LhMessage[], event: Record<string, unknown>): boolean {
	const result = applyLiveEvent(layer.buffer, event, {
		inRecord: (id) => record.some((m) => m.id === id),
		mintId: mintLiveId,
	});
	if (result.kind === "loop-error") layer.loopError = result.errorText;
	else if (result.kind === "agent-start") layer.loopError = null;
	else if (result.kind === "assistant") {
		if (result.phase === "message_end") {
			layer.incompleteUsageIds.delete(result.id);
			const message = result.message as LhMessage & { stopReason?: string };
			if (message.role === "assistant" && message.stopReason === "error") {
				layer.liveFailureId = result.id;
				layer.loopError = null;
			}
		} else layer.incompleteUsageIds.add(result.id);
	}
	return liveEventActed(result);
}

// ─── redaction ──────────────────────────────────────────────────────────────

const QUESTION_SECRETS = ["correctAnswer", "explanation"] as const;

function without(value: unknown, keys: readonly string[]): unknown {
	if (!value || typeof value !== "object" || Array.isArray(value)) return value;
	if (!keys.some((key) => key in (value as Record<string, unknown>))) return value;
	const copy = { ...(value as Record<string, unknown>) };
	for (const key of keys) delete copy[key];
	return copy;
}

/** Unanswered question calls never expose their answer; posed problems never
 *  expose the model solution (the conclude part's `reveal` carries it once
 *  the problem is concluded). Never mutates record objects. */
function redactPart(part: LhViewPart): LhViewPart {
	if (!part.type.startsWith("tool-")) return part;
	const tool = part.type.slice("tool-".length);
	if ((QUESTION_TOOLS as readonly string[]).includes(tool) && part.state !== "output-available") {
		return { ...part, input: without(part.input, QUESTION_SECRETS), rawInput: without(part.rawInput, QUESTION_SECRETS) };
	}
	if (tool === "problem") {
		return { ...part, input: without(part.input, ["modelSolution"]), rawInput: without(part.rawInput, ["modelSolution"]) };
	}
	return part;
}

// ─── display text (owner 2026-11-07) ────────────────────────────────────────
// The web normalizes math at render time: prose through
// transformMathDelimiters (legacy \(...\) / \[...\] → dollar math),
// tool-authored content additionally through repairMathForDisplay (the
// display-only recovery of JSON-swallowed backslashes). The native view
// applies the same functions to the same fields, so Swift renders only
// standard $...$ / $$...$$. The record itself is never rewritten.

const displayProse = (text: string): string => transformMathDelimiters(text);
const displayTool = (text: string): string => transformMathDelimiters(repairMathForDisplay(text));

type Fields = Record<string, unknown>;

function mapStrings(value: unknown, keys: readonly string[], fn: (text: string) => string): unknown {
	if (!value || typeof value !== "object" || Array.isArray(value)) return value;
	const source = value as Fields;
	let copy: Fields | undefined;
	for (const key of keys) {
		if (typeof source[key] !== "string") continue;
		copy ??= { ...source };
		copy[key] = fn(source[key] as string);
	}
	return copy ?? value;
}

function mapOptions(value: unknown, fn: (text: string) => string): unknown {
	if (!value || typeof value !== "object" || Array.isArray(value)) return value;
	const options = (value as Fields).options;
	if (!Array.isArray(options)) return value; // string-encoded options stay raw (parsed by the reader)
	return { ...(value as Fields), options: options.map((o) => mapStrings(o, ["label", "description"], fn)) };
}

function displayPart(part: LhViewPart): LhViewPart {
	if ((part.type === "text" || part.type === "reasoning") && typeof part.text === "string") {
		return { ...part, text: displayProse(part.text) };
	}
	if (!part.type.startsWith("tool-")) return part;
	const tool = part.type.slice("tool-".length);
	if ((QUESTION_TOOLS as readonly string[]).includes(tool)) {
		return {
			...part,
			input: mapOptions(mapStrings(part.input, ["question", "details"], displayTool), displayTool),
			output: mapOptions(mapStrings(part.output, ["questionText", "explanation", "committed"], displayTool), displayTool),
		};
	}
	if (tool === "problem") return { ...part, input: mapStrings(part.input, ["statement"], displayTool) };
	if (tool === "conclude") {
		const next: LhViewPart = { ...part, input: mapStrings(part.input, ["verdict", "solutionReveal"], displayTool) };
		if (typeof part.reveal === "string") next.reveal = displayTool(part.reveal);
		return next;
	}
	return part;
}

function nativeMessages(view: readonly LhViewMessage[]): NativeViewMessage[] {
	return view.map((m) => {
		const message: NativeViewMessage = { id: m.id, role: m.role, parts: m.parts.map((part) => displayPart(redactPart(part))) };
		if (m.metadata !== undefined) message.metadata = m.metadata;
		return message;
	});
}

// ─── the view ───────────────────────────────────────────────────────────────

function posedAnyProblem(messages: readonly LhMessage[]): boolean {
	return messages.some((m) => m.role === "assistant" && m.content.some((b) => b.type === "toolCall" && b.name === "problem"));
}

function dockOf(
	kind: "teach" | "practice",
	native: readonly LhMessage[],
	view: LhViewMessage[],
	busy: boolean,
): NativeDock | null {
	const pending = findPendingToolCall(view, pendingQuestionOf(native));
	if (pending) {
		try {
			const questionKind = toolQuestionKind(pending.tool);
			const data = questionDataFromCall(questionKind, pending.toolCallId, pending.input as Parameters<typeof questionDataFromCall>[2]);
			const client = toClientQuestion(data);
			return {
				type: "question",
				toolCallId: pending.toolCallId,
				key: pending.key,
				tool: pending.tool,
				kind: client.kind,
				...(data.questionType ? { questionType: data.questionType } : {}),
				question: displayTool(client.question),
				...(client.context !== undefined ? { context: displayTool(client.context) } : {}),
				mode: client.mode,
				options: client.options.map((o) => ({
					...o,
					label: displayTool(o.label),
					...(o.description !== undefined ? { description: displayTool(o.description) } : {}),
				})),
				needsReveal: questionNeedsReveal(pending.tool, pending.input, phaseAt3(view)),
				confidenceStops: [...CONFIDENCE_STOPS],
				defaultConfidenceIndex: DEFAULT_CONFIDENCE_INDEX,
			};
		} catch {
			return null; // an unrenderable question surfaces through malformedQuestions
		}
	}
	const problem = activeProblemOf(native);
	if (problem) {
		const input = (problem.input ?? {}) as { statement?: unknown; mode?: unknown };
		return {
			type: "problem",
			toolCallId: problem.toolCallId,
			...(typeof input.statement === "string" ? { statement: displayTool(input.statement) } : {}),
			...(typeof input.mode === "string" ? { mode: input.mode } : {}),
		};
	}
	if (kind === "practice" && !busy && posedAnyProblem(native)) return { type: "between-problems" };
	return null;
}

/** Project one session for the native client. `live` is the running turn's
 *  layer when this view is attached to a stream; null projects the record. */
export function buildNativeView(chat: ChatRecord, live: NativeLiveLayer | null = null, revision = 0): NativeSessionView {
	const native: LhMessage[] = live ? [...chat.messages, ...live.buffer.tail] : chat.messages;
	const view = projectView(native, live ? liveTurnState(live.buffer) : undefined);
	const kind = chat.kind === "practice" ? "practice" : "teach";
	const running = live !== null || isTurnRunning(chat.id);
	const compacting = !running && compactionInFlight(chat.id);
	const status = running ? "running" : compacting ? "compacting" : "idle";

	let failure: NativeSessionState["failure"] = null;
	const canRetry = !running && endsInFailedTurn(chat.messages);
	if (live?.loopError) failure = { message: live.loopError, canRetry: false };
	else {
		const retained = running ? undefined : turnFailure(chat.id);
		const latest = failedResponseAtEnd(native);
		if (retained !== undefined) failure = { message: retained, canRetry };
		else if (latest && (!running || latest.id === live?.liveFailureId)) {
			failure = { message: latest.errorMessage ?? "An error occurred.", canRetry };
		}
	}

	const tree = latestPlanTree(view);
	const statuses = tree ? derivePlanStatuses(tree, view) : null;
	const pricing = sessionCost(chat);
	const coverage = sessionCoverage(chat.id);

	return {
		version: NATIVE_VIEW_VERSION,
		chatId: chat.id,
		title: chat.title,
		kind,
		createdAt: chat.createdAt,
		updatedAt: chat.updatedAt,
		revision,
		status,
		phase: kind === "practice" ? null : phaseAt3(view),
		activity: running ? streamingToolActivity(view) : null,
		dock: dockOf(kind, native, view, running || compacting),
		malformedQuestions: malformedQuestionsOf(native).map((q) => ({
			toolCallId: q.toolCallId, messageId: q.messageId, contentIndex: q.contentIndex, tool: q.tool,
		})),
		plan: tree && statuses ? { tree, current: statuses.current, visited: [...statuses.visited] } : null,
		needsContinuation: !running && !compacting && needsContinuation(chat.messages),
		failure,
		usage: {
			contextTokens: measuredContextTokens(native, live?.incompleteUsageIds ?? new Set()),
			cost: pricing.cost,
			unpriced: pricing.unpriced,
			...(pricing.subscription !== undefined ? { subscription: pricing.subscription } : {}),
		},
		settings: chat.settings ?? null,
		coverage,
		messages: nativeMessages(view),
	};
}

/** GET /api/native/chats/:id/view — the standalone snapshot. */
export function nativeViewResponse(chatId: string): Response {
	const chat = getChat(chatId);
	if (!chat) return Response.json({ error: "Not found" }, { status: 404 });
	return Response.json(buildNativeView(chat), { headers: { "Cache-Control": "no-store" } });
}

// ─── the stream ─────────────────────────────────────────────────────────────

const SSE_HEADERS = {
	"Content-Type": "text/event-stream",
	"Cache-Control": "no-cache, no-transform",
	"X-Accel-Buffering": "no",
};

function frameBytes(frame: NativeStreamFrame | "[DONE]"): Uint8Array {
	return new TextEncoder().encode(`data: ${frame === "[DONE]" ? frame : JSON.stringify(frame)}\n\n`);
}

/** Message-level diffing for patch frames within one stream. */
export class NativeFrameDiffer {
	private sent = new Map<string, string>();
	private order: string[] = [];
	private lastState = "";
	private revision = 0;

	private static stateKey(view: NativeSessionView): string {
		const { messages: _messages, ...state } = view;
		return JSON.stringify({ ...state, revision: 0 });
	}

	/** A full frame (snapshot/settled): the next patch diffs against it. */
	snapshot(view: NativeSessionView, type: "snapshot" | "settled"): NativeStreamFrame {
		this.revision++;
		const stamped = { ...view, revision: this.revision };
		this.sent = new Map(stamped.messages.map((m) => [m.id, JSON.stringify(m)]));
		this.order = stamped.messages.map((m) => m.id);
		this.lastState = NativeFrameDiffer.stateKey(view);
		return { type, view: stamped };
	}

	/** null when nothing at all changed since the previous frame. */
	patch(view: NativeSessionView): NativeStreamFrame | null {
		const { messages, ...state } = view;
		const changed: NativeViewMessage[] = [];
		const next = new Map<string, string>();
		for (const message of messages) {
			const json = JSON.stringify(message);
			next.set(message.id, json);
			if (this.sent.get(message.id) !== json) changed.push(message);
		}
		const order = messages.map((m) => m.id);
		const sameOrder = order.length === this.order.length && order.every((id, i) => this.order[i] === id);
		const stateKey = NativeFrameDiffer.stateKey(view);
		if (changed.length === 0 && sameOrder && stateKey === this.lastState) return null;
		this.sent = next;
		this.order = order;
		this.lastState = stateKey;
		this.revision++;
		return { type: "patch", state: { ...state, revision: this.revision }, order, messages: changed };
	}
}

/** GET /api/native/chats/:id/stream — the turn-scoped native wire. A running
 *  turn: snapshot (record + replayed live state) → patches → settled (the
 *  persisted record). No turn: one settled frame. Detaching never touches
 *  the turn. Idle-time changes reach clients through /api/events. */
export function nativeStreamResponse(chatId: string, options: { coalesceMs?: number } = {}): Response {
	const initial = getChat(chatId);
	if (!initial) return Response.json({ error: "Not found" }, { status: 404 });
	const handle = runningTurn(chatId);
	const differ = new NativeFrameDiffer();
	if (!handle) {
		const view = buildNativeView(initial);
		const body = new Uint8Array([...frameBytes(differ.snapshot(view, "settled")), ...frameBytes("[DONE]")]);
		return new Response(body, { headers: SSE_HEADERS });
	}

	const coalesceMs = options.coalesceMs ?? 50;
	let cleanup = () => {};
	const stream = new ReadableStream<Uint8Array>({
		start(controller) {
			let record = initial;
			const layer = emptyNativeLiveLayer();
			let replaying = true;
			let finished = false;
			let closed = false;
			let timer: ReturnType<typeof setTimeout> | undefined;

			const enqueue = (frame: NativeStreamFrame | "[DONE]") => {
				if (closed) return;
				try { controller.enqueue(frameBytes(frame)); }
				catch { closed = true; }
			};
			const flush = () => {
				timer = undefined;
				if (finished || closed) return;
				const frame = differ.patch(buildNativeView(record, layer));
				if (frame) enqueue(frame);
			};
			const schedule = () => {
				if (replaying || finished || timer !== undefined) return;
				timer = setTimeout(flush, coalesceMs);
				(timer as { unref?: () => void }).unref?.();
			};
			const finish = () => {
				if (finished) return;
				finished = true;
				if (timer !== undefined) { clearTimeout(timer); timer = undefined; }
				// The settle seam persisted the record before closing views.
				const settled = getChat(chatId) ?? record;
				enqueue(differ.snapshot(buildNativeView(settled), "settled"));
				enqueue("[DONE]");
				cleanup();
				if (!closed) { closed = true; try { controller.close(); } catch { /* cancelled */ } }
			};

			// Append-only adoption mid-turn (the web rule): content delivered
			// into the record while the turn runs becomes visible at once.
			const unsubscribe = subscribeServerEvents((event) => {
				if (event.type !== "record-changed" || (event as { chatId?: string }).chatId !== chatId || finished) return;
				const next = getChat(chatId);
				if (!next) return;
				const ids = new Set(next.messages.map((m) => m.id));
				if (record.messages.some((m) => !ids.has(m.id))) return; // not a pure append
				record = next;
				layer.buffer.tail = layer.buffer.tail.filter((m) => !ids.has(m.id));
				schedule();
			});

			let detach = () => {};
			cleanup = () => {
				unsubscribe();
				detach();
				if (timer !== undefined) { clearTimeout(timer); timer = undefined; }
			};
			let settledDuringReplay = false;
			detach = handle.attach({
				push(event) {
					applyNativeLiveEvent(layer, record.messages, event as unknown as Record<string, unknown>);
					schedule();
				},
				done() {
					if (replaying) settledDuringReplay = true;
					else finish();
				},
			});
			replaying = false;
			const view = buildNativeView(record, layer);
			enqueue(differ.snapshot(view, "snapshot"));
			if (settledDuringReplay) finish();
		},
		cancel() {
			cleanup();
		},
	});
	return new Response(stream, { headers: SSE_HEADERS });
}

// ─── answers ────────────────────────────────────────────────────────────────

/** POST /api/native/chats/:id/answer — {toolCallId, request: AnswerRequest}.
 *  The server shuffles and grades exactly like the web dock
 *  (answerInputFromRequest), then the answer rides the ordinary `answer`
 *  input through the same turn composition (same 409/sibling rules). */
export async function nativeAnswerResponse(
	chatId: string,
	request: Request,
	buildAgent?: Parameters<typeof handleChatInput>[2],
): Promise<Response> {
	const chat = getChat(chatId);
	if (!chat) return Response.json({ error: "Unknown chat" }, { status: 404 });
	let body: { toolCallId?: unknown; request?: unknown } | null;
	try { body = (await request.json()) as typeof body; }
	catch { return Response.json({ error: "Invalid JSON body" }, { status: 400 }); }
	let input;
	try {
		if (typeof body?.toolCallId !== "string" || body.toolCallId.length === 0) throw new ChatInputError("answer requires toolCallId");
		input = answerInputFromRequest(chat.messages, body.toolCallId, parseAnswerRequest(body.request));
	} catch (err) {
		if (err instanceof ChatInputError) return Response.json({ error: err.message }, { status: 400 });
		throw err;
	}
	return handleChatInput(chatId, input, buildAgent);
}
