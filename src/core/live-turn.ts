/**
 * THE LIVE-TURN REDUCER (iOS client, 2026-11-07): one application of a
 * running turn's wire events (pi AgentEvents + the app's loop error) onto
 * the live tail that projectView reads. Extracted verbatim from the web
 * SessionModel so the browser and the server-side native view (which
 * projects for the iOS client) merge live events by the same rules:
 *
 * - pi streams AssistantMessages with NO id: the in-flight message is
 *   tracked by SLOT — message_start mints and remembers the id; updates
 *   and the end REPLACE that same tail entry (exactly one assistant message
 *   streams at a time). An explicit message.id still wins.
 * - Markers injected mid-run arrive as custom-role start/end events and
 *   UPSERT by id — unless the record already carries that id.
 * - tool_execution_end feeds the execution layer (clean question
 *   placeholders are ignored downstream by projectView).
 * - turn_end appends the results batch with minted ids (the settle sync
 *   lands the server canon).
 *
 * Pure apart from the injected id minting; replaces tail/executions
 * immutably, as the web model always did.
 */

import type { AgentEvent } from "@earendil-works/pi-agent-core";
import type { ToolResultMessage } from "@earendil-works/pi-ai";
import type { LhMessage } from "./native-messages.ts";
import type { LiveExecution, LiveTurnState } from "./view.ts";

export interface LiveTurnBuffer {
	/** The turn's streamed messages after the record (and any optimistic appends). */
	tail: LhMessage[];
	/** toolCallId → execution outcome seen so far. */
	executions: Map<string, LiveExecution>;
	/** Ids of messages streamed by this consume (the thinking row's evidence). */
	streamingIds: Set<string>;
	/** The in-flight assistant message's slot id. */
	streamingMessageId: string | null;
}

export function emptyLiveTurnBuffer(): LiveTurnBuffer {
	return { tail: [], executions: new Map(), streamingIds: new Set(), streamingMessageId: null };
}

/** The projectView live layer for a buffer whose turn is running. */
export function liveTurnState(buffer: LiveTurnBuffer): LiveTurnState {
	return { executions: buffer.executions, inFlight: true, streamingIds: buffer.streamingIds };
}

export type LiveEventResult =
	| { kind: "loop-error"; errorText: string }
	| { kind: "agent-start" }
	| { kind: "ignored" }
	| { kind: "marker" }
	| { kind: "assistant"; phase: "message_start" | "message_update" | "message_end"; id: string; message: LhMessage }
	| { kind: "execution" }
	| { kind: "tool-results" };

export interface LiveEventContext {
	/** Does the durable record already own this message id? */
	inRecord(id: string): boolean;
	/** A fresh local id for unstamped live messages. */
	mintId(): string;
}

/** Did this result do VIEW work (the first acted event flips a consume to streaming)? */
export function liveEventActed(result: LiveEventResult): boolean {
	return result.kind !== "loop-error" && result.kind !== "agent-start" && result.kind !== "ignored";
}

export function applyLiveEvent(buffer: LiveTurnBuffer, event: Record<string, unknown>, context: LiveEventContext): LiveEventResult {
	if (event.type === "error") {
		// Loop-level failure (agent.continue threw outside the stream): raw text.
		return { kind: "loop-error", errorText: String(event.errorText ?? "An error occurred.") };
	}
	const agent = event as unknown as AgentEvent;
	switch (agent.type) {
		case "agent_start":
			return { kind: "agent-start" };
		case "message_start":
		case "message_update":
		case "message_end": {
			const message = agent.message as LhMessage & { role?: string; id?: string };
			if ((message as { role?: string }).role !== "assistant") {
				const mid = message.id;
				if (mid === undefined) return { kind: "ignored" };
				// The record owns a durable identity; adding it to the tail would
				// duplicate it until the next sync.
				if (context.inRecord(mid)) return { kind: "ignored" };
				const idx = buffer.tail.findIndex((m) => m.id === mid);
				buffer.tail = idx === -1 ? [...buffer.tail, message as LhMessage] : buffer.tail.with(idx, message as LhMessage);
				return { kind: "marker" };
			}
			const id = message.id ?? buffer.streamingMessageId ?? context.mintId();
			const withId = { ...message, id } as LhMessage;
			if (agent.type === "message_start") {
				buffer.streamingMessageId = id;
				buffer.streamingIds.add(id);
				buffer.tail = [...buffer.tail, withId];
			} else {
				const idx = buffer.tail.findIndex((m) => m.id === id);
				buffer.tail = idx === -1 ? [...buffer.tail, withId] : buffer.tail.with(idx, withId);
			}
			if (agent.type === "message_end") buffer.streamingMessageId = null; // slot done
			return { kind: "assistant", phase: agent.type, id, message: withId };
		}
		case "tool_execution_end": {
			const result = agent.result as
				| { content?: Array<{ type?: string; text?: string }>; details?: unknown }
				| null;
			const text = result?.content?.find((c) => c.type === "text")?.text ?? "The tool call failed.";
			buffer.executions = new Map(buffer.executions).set(agent.toolCallId, {
				isError: agent.isError,
				output: result?.details,
				errorText: text,
			});
			return { kind: "execution" };
		}
		case "turn_end": {
			buffer.tail = [
				...buffer.tail,
				...(agent.toolResults as ToolResultMessage[]).map(
					(r) => ({ ...r, id: context.mintId() }) as unknown as LhMessage,
				),
			];
			return { kind: "tool-results" };
		}
		default:
			return { kind: "ignored" }; // turn_start / tool_execution_start|update: no view work
	}
}
