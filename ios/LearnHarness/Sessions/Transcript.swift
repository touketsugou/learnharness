import LHAPI
import LHRender
import SwiftUI

/// The session transcript in the web's document style: learner rows are
/// full-width quote rows ("YOU" + rail), the agent's output is prose with
/// cards inline, markers render as cards or dividers.
struct TranscriptList: View {
	let model: SessionModel

	var body: some View {
		let messages = model.view?.messages ?? []
		let teachDivider = TranscriptPhases.teachDivider(in: messages)
		let pending = model.pendingText
		let steers = model.visibleSteers
		let placeholder = messages.isEmpty && !model.submitting && !model.isRunning
		let hasRows = !messages.isEmpty || placeholder
		// Each part of an assistant message is a row of its own, and each block of
		// its text. A row holding a whole message grows without bound over
		// consecutive questions, and one tall row near the bottom makes the lazy
		// stack's height estimate run far past the real content, which leaves the
		// bottom-anchored viewport in empty space.
		LazyVStack(alignment: .leading, spacing: 10) {
			if placeholder {
				ContentUnavailableView("New session", systemImage: "sparkles", description: Text("The teacher will open by probing what you already know."))
			}
			ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
				MessageRow(
					model: model,
					message: message,
					isLast: index == messages.count - 1,
					teachBoundary: teachDivider?.messageIndex == index ? .some(teachDivider?.partIndex) : nil,
					hasPrevious: index > 0,
					beforeAssistant: index + 1 < messages.count && messages[index + 1].role == .assistant
				)
			}
			if let pending {
				UserRow(text: pending).opacity(0.6).messageGap(above: hasRows)
			}
			ForEach(Array(steers.enumerated()), id: \.element.id) { index, steer in
				UserRow(text: steer.text, label: "YOU · QUEUED").opacity(0.6)
					.messageGap(above: hasRows || pending != nil || index > 0)
			}
			StatusRows(model: model, hasPrevious: hasRows || pending != nil || !steers.isEmpty)
		}
	}
}

private extension View {
	/// Rows sit 10 apart, the gap between the parts of one message. Messages
	/// sit 14 apart: the rows that always draw (learner rows, the rows after
	/// the last message) add the other 4, since an assistant message's first
	/// or last part may draw nothing.
	func messageGap(above: Bool = false, below: Bool = false) -> some View {
		padding(.top, above ? 4 : 0).padding(.bottom, below ? 4 : 0)
	}
}

private struct MessageRow: View {
	let model: SessionModel
	let message: NativeViewMessage
	let isLast: Bool
	/// nil: no divider here; .some(nil): before the message; .some(i): at part i.
	let teachBoundary: Int??
	let hasPrevious: Bool
	let beforeAssistant: Bool

	var body: some View {
		if message.role == .user {
			userContent.messageGap(above: hasPrevious, below: beforeAssistant)
		} else {
			if case .some(.none) = teachBoundary { PhaseDivider(title: "Teaching") }
			ForEach(Array(message.parts.enumerated()), id: \.offset) { index, part in
				AssistantPart(model: model, message: message, part: part, index: index,
							  isLastPart: isLast && index == message.parts.count - 1,
							  teachBoundaryHere: teachBoundary == .some(.some(index)))
			}
		}
	}

	@ViewBuilder private var userContent: some View {
		let types = message.parts.map(\.type)
		if types.contains("data-subagent-artifact") || types.contains("data-subagent-aborted") {
			SteerArtifactCard(model: model, message: message)
		} else if types.contains("data-probe-handoff") {
			PhaseDivider(title: "Planning")
		} else if !types.isEmpty, types.allSatisfy({ $0.hasPrefix("data-") }) {
			VStack(alignment: .leading, spacing: 8) {
				ForEach(Array(message.parts.enumerated()), id: \.offset) { _, part in
					MarkerCard(part: part)
				}
			}
		} else {
			UserRow(text: message.parts.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n"))
		}
	}
}

/// The learner's words: a full-width band with a rail and the "YOU" label.
struct UserRow: View {
	let text: String
	var label = "YOU"

	var body: some View {
		HStack(spacing: 0) {
			Rectangle().fill(.secondary.opacity(0.35)).frame(width: 4)
			VStack(alignment: .leading, spacing: 4) {
				Text(label).font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
				FilePathText(text: text)
			}
			.padding(.vertical, 8)
			.padding(.horizontal, 12)
			Spacer(minLength: 0)
		}
		.background(Color(uiColor: .secondarySystemBackground))
		.clipShape(RoundedRectangle(cornerRadius: 6))
	}
}

/// Learner text with quoted server paths shown as file chips (desktop parity).
struct FilePathText: View {
	let text: String

	var body: some View {
		Text(Self.attributed(text)).textSelection(.enabled)
	}

	/// `path` spans that look like rooted paths become a 📎 chip with the file name.
	nonisolated static func attributed(_ text: String) -> AttributedString {
		var result = AttributedString()
		var rest = Substring(text)
		while let open = rest.firstIndex(of: "`") {
			let ticks = rest[open...].prefix { $0 == "`" }
			let afterOpen = rest.index(open, offsetBy: ticks.count)
			guard let close = rest[afterOpen...].range(of: String(ticks)) else { break }
			let inner = rest[afterOpen..<close.lowerBound].trimmingCharacters(in: .whitespaces)
			result += AttributedString(rest[..<open])
			if inner.hasPrefix("/") || inner.hasPrefix("~/") {
				var chip = AttributedString("📎 " + chipName(for: inner))
				chip.font = .callout.weight(.medium)
				chip.foregroundColor = .accentColor
				result += chip
			} else {
				result += AttributedString(rest[open..<close.upperBound])
			}
			rest = rest[close.upperBound...]
		}
		result += AttributedString(rest)
		return result
	}

	/// The chip's file name: the last path component, without the
	/// `<uuid>-` prefix the server gives uploads (src/server/native-uploads.ts).
	nonisolated static func chipName(for path: String) -> String {
		let name = (path as NSString).lastPathComponent
		guard let match = name.prefixMatch(of: /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}-/),
			match.output.count < name.count else { return name }
		return String(name[match.range.upperBound...])
	}
}

struct PhaseDivider: View {
	let title: String

	var body: some View {
		HStack(spacing: 10) {
			Rectangle().fill(.quaternary).frame(height: 1)
			Text(title.uppercased()).font(.caption2.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
				.lineLimit(1)
				.fixedSize()
			Rectangle().fill(.quaternary).frame(height: 1)
		}
		.padding(.vertical, 6)
	}
}

/// "Retrying…", the activity line, the compaction line, failures.
private struct StatusRows: View {
	let model: SessionModel
	/// Whether a row sits above these.
	let hasPrevious: Bool

	var body: some View {
		let working = working
		let failure = model.state?.failure
		if let working {
			WorkingLine(text: working).messageGap(above: hasPrevious)
		}
		if let failure {
			FailureBanner(message: failure.message, canRetry: failure.canRetry && model.canAct) {
				Task { await model.retryFailedTurn() }
			}
			.messageGap(above: hasPrevious || working != nil)
		}
		if let error = model.requestError {
			FailureBanner(message: error, canRetry: false) {}
				.messageGap(above: hasPrevious || working != nil || failure != nil)
		}
	}

	private var working: String? {
		if model.isCompacting { return "Compacting context…" }
		if model.submitting || (model.isRunning && model.view?.messages.last?.role != .assistant) { return "Thinking…" }
		return nil
	}
}

struct WorkingLine: View {
	let text: String

	var body: some View {
		HStack(spacing: 8) {
			ProgressView().controlSize(.small)
			Text(text.uppercased()).font(.caption.weight(.medium)).tracking(0.6).foregroundStyle(.secondary)
		}
	}
}

private struct FailureBanner: View {
	let message: String
	let canRetry: Bool
	let retry: () -> Void

	var body: some View {
		HStack(alignment: .top, spacing: 10) {
			Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
			Text("Something went wrong: \(message)").font(.callout)
			Spacer(minLength: 0)
			if canRetry {
				Button("Retry", action: retry).buttonStyle(.bordered).controlSize(.small)
			}
		}
		.padding(12)
		.background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.08)))
		.overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.red.opacity(0.35)))
	}
}

// MARK: - Assistant parts

private struct AssistantPart: View {
	let model: SessionModel
	let message: NativeViewMessage
	let part: NativeViewPart
	let index: Int
	let isLastPart: Bool
	let teachBoundaryHere: Bool

	var body: some View {
		if part.state == "output-error", part.toolName != nil, part.errorText != "Operation aborted" {
			// A call the agent will retry itself: one quiet line, never silence.
			WorkingLine(text: "Retrying…").opacity(0.7)
		} else {
			content
		}
	}

	@ViewBuilder private var content: some View {
		switch part.type {
		case "text":
			// A row per Markdown block, so a long reply makes no tall row. The
			// first block's id is the graph's scroll anchor (a proposition's
			// source passage).
			let text = part.text ?? ""
			let anchor = part.id ?? "\(message.id)-\(index)"
			ForEach(0..<MarkdownBlock.count(text), id: \.self) { block in
				MarkdownBlock(text, index: block).id(block == 0 ? anchor : "\(anchor)#\(block)")
			}
		case "reasoning":
			ReasoningRow(text: part.text ?? "", live: isLastPart && model.isRunning)
		case "step-start":
			if teachBoundaryHere { PhaseDivider(title: "Teaching") } else if index > 0 { Divider().padding(.vertical, 2) }
		case "data-plan-block":
			PlanBlockCard(data: part.data, model: model)
		case "tool-quiz", "tool-probe", "tool-ask_user_question", "tool-explain", "tool-recall":
			questionPart
		default:
			toolPart
		}
	}

	@ViewBuilder private var questionPart: some View {
		if let malformed = model.state?.malformedQuestions.first(where: {
			$0.toolCallId == part.toolCallId && $0.messageId == part["sourceMessageId"]?.stringValue && $0.contentIndex == part["sourceContentIndex"]?.intValue
		}), !model.isRunning {
			MalformedQuestionCard(blocked: isQuestionPending) {
				Task { await model.retryQuestion(malformed) }
			}
		} else if part.state == "output-available", let output = part.output {
			AnsweredCard(answer: output, input: part.input)
		}
	}

	private var isQuestionPending: Bool {
		if case .question = model.state?.dock { return true }
		return false
	}

	@ViewBuilder private var toolPart: some View {
		if let tool = part.toolName {
			if part.state == "input-streaming" {
				LiveToolRow(tool: tool)
			} else {
				switch tool {
				case "research", "pdf", "demo", "visual":
					if part.state == "output-available" { DispatchCard(model: model, kind: tool, toolCallId: part.toolCallId) }
				case "show_image":
					ShowImageCard(model: model, part: part)
				case "probe_done":
					ProbeDoneCard(part: part)
				case "read", "ls", "find", "grep", "list_sessions", "list_propositions":
					ToolCallRow(tool: tool, part: part)
				case "problem":
					ProblemCard(part: part)
				case "conclude":
					ConcludeCard(part: part)
				default:
					EmptyView()
				}
			}
		}
	}
}

private struct ReasoningRow: View {
	let text: String
	let live: Bool
	@State private var open = false

	var body: some View {
		if text.isEmpty && live {
			WorkingLine(text: "Thinking…")
		} else if !text.isEmpty {
			DisclosureGroup(isExpanded: $open) {
				MarkdownView(text, textStyle: .callout)
					.foregroundStyle(.secondary)
					.padding(.top, 4)
			} label: {
				HStack(spacing: 6) {
					if live { ProgressView().controlSize(.mini) }
					Text("THINKING").font(.caption.weight(.medium)).tracking(0.6).foregroundStyle(.secondary)
				}
			}
			.tint(.secondary)
		}
	}
}

/// A tool call being written — the web's live tool card label.
private struct LiveToolRow: View {
	let tool: String

	var body: some View { WorkingLine(text: Self.label(tool)) }

	static let labels: [String: String] = [
		"read": "Reading a file…", "ls": "Listing a directory…", "find": "Finding files…", "grep": "Searching file contents…",
		"research": "Dispatching research…", "demo": "Building a demo…", "visual": "Making a visual…", "pdf": "Reading a PDF…",
		"plan_init": "Drawing up the plan…", "probe_done": "Concluding the assessment…",
	]
	static let questionTools: Set<String> = ["quiz", "probe", "recall", "explain", "ask_user_question"]

	static func label(_ tool: String) -> String {
		questionTools.contains(tool) ? "Writing a question…" : labels[tool] ?? "Working…"
	}
}
