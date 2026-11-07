import LHAPI
import LHRender
import SwiftUI

// Transcript cards — native counterparts of the web's artifact registry,
// answered card, practice cards and marker cards (components/*).

struct CardBox<Content: View>: View {
	var tint: Color? = nil
	@ViewBuilder let content: Content

	var body: some View {
		VStack(alignment: .leading, spacing: 8) { content }
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(14)
			.background(RoundedRectangle(cornerRadius: 12).fill(tint?.opacity(0.08) ?? Color(uiColor: .secondarySystemBackground)))
			.overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
	}
}

struct CardLabel: View {
	let text: String
	var systemImage: String?

	var body: some View {
		HStack(spacing: 6) {
			if let systemImage { Image(systemName: systemImage) }
			Text(text.uppercased()).tracking(0.6)
		}
		.font(.caption.weight(.medium))
		.foregroundStyle(.secondary)
	}
}

private struct Badge: View {
	let text: String
	let color: Color

	var body: some View {
		Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
			.background(Capsule().fill(color.opacity(0.15))).foregroundStyle(color)
	}
}

// MARK: - Answered questions

struct AnsweredCard: View {
	let answer: JSONValue
	let input: JSONValue?
	@State private var whyOpen = false

	private var kind: String { answer["kind"]?.stringValue ?? "" }

	private var label: String {
		switch answer["tool"]?.stringValue {
		case "probe": return "Probe"
		case "recall": return "Recall"
		default:
			if kind == "quiz" { return answer["questionType"]?.stringValue == "predict" ? "Prediction" : "Check" }
			return kind == "explain" ? "Explain" : "Question"
		}
	}

	var body: some View {
		if answer["dismissed"]?.boolValue == true {
			CardBox {
				Text("\(answer["questionText"]?.stringValue ?? "") — skipped").font(.callout).foregroundStyle(.secondary)
			}
		} else {
			VStack(alignment: .leading, spacing: 10) {
				if let reading = answer["readingThinking"]?.stringValue, !reading.isEmpty {
					ThinkingQuote(label: "YOUR THINKING", text: reading)
				}
				CardBox {
					HStack(spacing: 8) {
						CardLabel(text: label)
						if kind == "quiz" {
							if answer["dontKnow"]?.boolValue == true { Badge(text: "didn't know", color: .secondary) }
							else if answer["correct"]?.boolValue == true { Badge(text: "correct", color: .green) }
							else { Badge(text: "incorrect", color: .red) }
						}
						Spacer()
						if kind == "quiz", answer["dontKnow"]?.boolValue != true, let confidence = answer["confidence"]?.intValue {
							Text("\(confidence)% sure").font(.caption).foregroundStyle(.secondary)
						}
					}
					MarkdownView(answer["questionText"]?.stringValue ?? "").fontWeight(.medium)
					if let details = input?["details"]?.stringValue, !details.isEmpty {
						MarkdownView(details, textStyle: .callout).foregroundStyle(.secondary)
					}
					options
					if let other = answer["other"]?.stringValue { answerLine("Your answer", other) }
					if let text = answer["text"]?.stringValue { answerLine("Your answer", text) }
					if let thinking = answer["thinking"]?.stringValue ?? answer["note"]?.stringValue, !thinking.isEmpty {
						ThinkingQuote(label: "YOUR THINKING", text: thinking)
					}
					if kind == "quiz", let explanation = answer["explanation"]?.stringValue, !explanation.isEmpty {
						if answer["questionType"]?.stringValue == "predict" {
							DisclosureGroup("Why", isExpanded: $whyOpen) { MarkdownView(explanation, textStyle: .callout) }
								.font(.callout)
						} else {
							MarkdownView(explanation, textStyle: .callout)
						}
					}
					if kind == "explain", let committed = answer["committed"]?.stringValue, !committed.isEmpty {
						VStack(alignment: .leading, spacing: 4) {
							CardLabel(text: "Expected answer")
							MarkdownView(committed, textStyle: .callout)
						}
					}
				}
			}
		}
	}

	@ViewBuilder private var options: some View {
		let selected = Set((answer["answers"]?.arrayValue ?? []).compactMap { $0["index"]?.intValue })
		let correct = Set((answer["correctIndices"]?.arrayValue ?? []).compactMap(\.intValue))
		let list = answer["options"]?.arrayValue ?? []
		if !list.isEmpty {
			VStack(alignment: .leading, spacing: 6) {
				ForEach(Array(list.enumerated()), id: \.offset) { _, option in
					let index = option["index"]?.intValue ?? 0
					HStack(alignment: .firstTextBaseline, spacing: 8) {
						Image(systemName: selected.contains(index) ? "largecircle.fill.circle" : "circle")
							.foregroundStyle(selected.contains(index) ? Color.accentColor : .secondary)
							.font(.footnote)
						MarkdownView(option["label"]?.stringValue ?? "", textStyle: .callout)
						if kind == "quiz", correct.contains(index) {
							Image(systemName: "checkmark").foregroundStyle(.green).font(.footnote.weight(.bold))
						}
					}
				}
			}
		}
	}

	private func answerLine(_ title: String, _ text: String) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			CardLabel(text: title)
			Text(text).font(.callout).textSelection(.enabled)
		}
	}
}

/// The learner's own thinking: italic, muted, behind a rail.
struct ThinkingQuote: View {
	let label: String
	let text: String
	@State private var open = true

	var body: some View {
		HStack(spacing: 0) {
			Rectangle().fill(.secondary.opacity(0.3)).frame(width: 3)
			DisclosureGroup(isExpanded: $open) {
				Text(text).font(.callout).italic().foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
			} label: {
				Text(label).font(.caption2.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
			}
			.tint(.secondary)
			.padding(.leading, 10)
		}
	}
}

struct MalformedQuestionCard: View {
	let blocked: Bool
	let retry: () -> Void

	var body: some View {
		CardBox(tint: .orange) {
			CardLabel(text: "Question could not be displayed", systemImage: "exclamationmark.bubble")
			Text(blocked ? "Answer or discard the remaining question first." : "The teacher's question arrived incomplete. Ask for a replacement.")
				.font(.callout).foregroundStyle(.secondary)
			Button("Ask again", action: retry).buttonStyle(.bordered).disabled(blocked)
		}
	}
}

// MARK: - Tool calls

struct ToolCallRow: View {
	let tool: String
	let part: NativeViewPart
	@State private var open = false

	private var headline: String {
		let input = part.input
		if ["read", "ls", "show_image"].contains(tool) { return input?["path"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? "~" }
		if let pattern = input?["pattern"]?.stringValue { return pattern }
		if tool == "list_propositions", let session = input?["session"]?.stringValue { return session }
		return ""
	}

	private var output: String? {
		guard let output = part.output, !output.isNull else { return nil }
		if let text = output.stringValue { return text }
		if let text = output["text"]?.stringValue {
			let images = output["images"]?.arrayValue?.count ?? 0
			return images > 0 ? "\(text)\n[\(images) image\(images > 1 ? "s" : "") attached to the model]" : text
		}
		return (try? String(data: JSONEncoder().encode(output), encoding: .utf8)) ?? nil
	}

	var body: some View {
		DisclosureGroup(isExpanded: $open) {
			if let output {
				ScrollView(.horizontal) {
					Text(output.count > 4000 ? String(output.prefix(4000)) + "\n…" : output)
						.font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
				}
				.frame(maxHeight: 240)
			}
		} label: {
			HStack(spacing: 6) {
				Image(systemName: part.state == "output-error" ? "xmark.circle" : "terminal")
				Text(tool).font(.caption.weight(.semibold))
				Text(headline).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
			}
			.foregroundStyle(.secondary)
		}
		.tint(.secondary)
	}
}

struct ProbeDoneCard: View {
	let part: NativeViewPart

	var body: some View {
		CardBox {
			CardLabel(text: "Probe concluded — your assessment", systemImage: "checkmark.clipboard")
			if let output = part.output, output["ok"]?.boolValue == false {
				Text("The prober retried: \(output["error"]?.stringValue ?? "")").font(.callout).foregroundStyle(.secondary)
			} else if part.state == "output-error" {
				Text("The assessment was malformed — the prober retried with a corrected one.").font(.callout).foregroundStyle(.secondary)
			} else {
				let assessment = part.input?["assessment"]
				ForEach(Array((assessment?["strands"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, strand in
					VStack(alignment: .leading, spacing: 2) {
						Text(strand["strand"]?.stringValue ?? "").font(.callout.weight(.medium))
						Text(strand["assessment"]?.stringValue ?? "").font(.callout).foregroundStyle(.secondary)
					}
				}
				if let summary = assessment?["summary"]?.stringValue {
					Text(summary).font(.callout).foregroundStyle(.secondary)
				}
			}
		}
	}
}

// MARK: - Background jobs

private let jobLabels = ["research": "Research agent", "demo": "Demo agent", "visual": "Figure agent", "pdf": "PDF reader"]

struct DispatchCard: View {
	let model: SessionModel
	let kind: String
	let toolCallId: String?

	var body: some View {
		let label = jobLabels[kind] ?? kind
		if let job = model.job(forToolCall: toolCallId), !job.isRunning {
			HStack(spacing: 6) {
				Image(systemName: job.status == "error" ? "xmark" : "checkmark")
					.foregroundStyle(job.status == "error" ? .red : .secondary)
				Text(label.uppercased()).tracking(0.6).font(.caption.weight(.medium))
				Text(job.status == "error" ? "failed" : "finished").font(.caption)
				if job.status == "error", let error = job.error { Text("· \(error)").font(.caption).lineLimit(2) }
			}
			.foregroundStyle(.secondary)
		} else {
			let job = model.job(forToolCall: toolCallId)
			CardBox {
				HStack(spacing: 8) {
					ProgressView().controlSize(.small)
					CardLabel(text: label)
					if let job { TimelineView(.periodic(from: .now, by: 1)) { _ in Text(elapsed(job)).font(.caption).foregroundStyle(.secondary) } }
					Spacer()
					if let job {
						Button("Stop", role: .destructive) { Task { await model.stopJob(job) } }
							.buttonStyle(.borderless).font(.caption)
					}
				}
				if let activity = job?.activity, !activity.isEmpty {
					Text(activity).font(.callout).foregroundStyle(.secondary).lineLimit(1)
				}
			}
		}
	}

	private func elapsed(_ job: JobRecord) -> String {
		guard let start = ISO8601DateFormatter.lhFractional.date(from: job.createdAt) else { return "" }
		return "· \(max(0, Int(Date().timeIntervalSince(start))))s"
	}
}

/// A delivered background result (the steer marker's artifact).
struct SteerArtifactCard: View {
	let model: SessionModel
	let message: NativeViewMessage

	var body: some View {
		if let data = message.parts.first(where: { $0.type == "data-subagent-artifact" })?.data {
			let result = data["result"]
			let inverted = data["ui"]?["inverted"]?.boolValue ?? false
			switch data["kind"]?.stringValue {
			case "research":
				ResearchResultCard(result: result, title: "Research", failedPrefix: "Research failed")
			case "pdf":
				ResearchResultCard(result: result, title: "PDF", failedPrefix: "PDF failed")
			case "demo":
				DemoArtifactCard(model: model, messageId: message.id, result: result, inverted: inverted)
			case "visual":
				VisualArtifactCard(model: model, messageId: message.id, result: result, inverted: inverted)
			default:
				CardBox { Text("A sub-agent finished, but its result could not be displayed.").font(.callout).foregroundStyle(.secondary) }
			}
		} else if let aborted = message.parts.first(where: { $0.type == "data-subagent-aborted" })?.data {
			HStack(spacing: 6) {
				Image(systemName: "xmark.circle")
				Text((aborted["kind"]?.stringValue ?? "job").uppercased()).tracking(0.6).font(.caption.weight(.medium))
				Text("aborted by the learner").font(.caption)
			}
			.foregroundStyle(.secondary)
		}
	}
}

private struct ResearchResultCard: View {
	let result: JSONValue?
	let title: String
	let failedPrefix: String
	@State private var open = false

	var body: some View {
		let brief = result?["brief"]?.stringValue ?? ""
		let sources = result?["sources"]?.arrayValue ?? []
		let pages = result?["pagesRead"]?.arrayValue ?? result?["pagesConsulted"]?.arrayValue ?? []
		if brief.hasPrefix(failedPrefix) {
			CardBox(tint: .red) {
				CardLabel(text: title)
				MarkdownView(brief, textStyle: .callout)
			}
		} else {
			DisclosureGroup(isExpanded: $open) {
				VStack(alignment: .leading, spacing: 8) {
					MarkdownView(brief, textStyle: .callout)
					ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
						if let url = source["url"]?.stringValue.flatMap(URL.init(string:)) {
							Link(source["title"]?.stringValue ?? url.absoluteString, destination: url).font(.callout)
						}
					}
				}
				.padding(.top, 6)
			} label: {
				HStack(spacing: 6) {
					Image(systemName: "checkmark")
					Text(title.uppercased()).tracking(0.6).font(.caption.weight(.medium))
					Text(title == "PDF" ? "reading complete" : "complete").font(.caption)
					if !sources.isEmpty { Text("· \(sources.count) sources").font(.caption) }
					if !pages.isEmpty { Text("· read \(pages.count) page\(pages.count == 1 ? "" : "s")").font(.caption) }
				}
				.foregroundStyle(.secondary)
			}
			.tint(.secondary)
		}
	}
}

/// Colour inversion for demos and figures (persisted per artifact, like the web).
private struct InvertToggle: View {
	@Binding var inverted: Bool
	let onChange: (Bool) -> Void

	var body: some View {
		Toggle(isOn: Binding(get: { inverted }, set: { inverted = $0; onChange($0) })) {
			Image(systemName: "circle.lefthalf.filled")
		}
		.toggleStyle(.button)
		.controlSize(.small)
		.accessibilityLabel("Invert colours")
	}
}

private struct DemoArtifactCard: View {
	let model: SessionModel
	let messageId: String
	let result: JSONValue?
	@State var inverted: Bool

	var body: some View {
		let html = result?["html"]?.stringValue ?? ""
		CardBox {
			HStack {
				CardLabel(text: result?["title"]?.stringValue ?? "Interactive demo", systemImage: "play.rectangle")
				Spacer()
				if !html.isEmpty {
					InvertToggle(inverted: $inverted) { value in Task { await model.setInverted(messageId: messageId, inverted: value) } }
				}
			}
			if html.isEmpty {
				Text(result?["notes"]?.stringValue ?? "The demo could not be built.").font(.callout).foregroundStyle(.secondary)
			} else {
				WebCardView(content: WebCardContent(html: html, pageScripts: true), maxHeight: 640)
					.colorInvert(inverted)
					.clipShape(RoundedRectangle(cornerRadius: 8))
			}
		}
	}
}

private struct VisualArtifactCard: View {
	let model: SessionModel
	let messageId: String
	let result: JSONValue?
	@State var inverted: Bool
	@State private var svg: String?

	var body: some View {
		let raw = result?["svg"]?.stringValue ?? ""
		let snapshotId = result?["image"]?["snapshotId"]?.stringValue
		CardBox {
			HStack {
				CardLabel(text: "Figure", systemImage: "photo")
				Spacer()
				if !raw.isEmpty, snapshotId == nil {
					InvertToggle(inverted: $inverted) { value in Task { await model.setInverted(messageId: messageId, inverted: value) } }
				}
			}
			if raw.isEmpty {
				Text(result?["notes"]?.stringValue ?? "The figure could not be drawn.").font(.callout).foregroundStyle(.secondary)
			} else if let svg {
				SVGView(svg: svg).colorInvert(inverted && snapshotId == nil)
			} else {
				ProgressView()
			}
		}
		.task(id: raw) {
			guard let snapshotId else { svg = raw; return }
			if let image = await model.imageSnapshot(snapshotId) {
				svg = LearnerImage.embed(raw, dataURI: image.dataURI)
			} else {
				svg = raw
			}
		}
	}
}

/// src/core/learner-image-svg.ts embedLearnerImage: the annotator's
/// placeholder href on <image> elements becomes the snapshot's data URI.
enum LearnerImage {
	static let placeholder = "learner-image"

	static func embed(_ svg: String, dataURI: String) -> String {
		let pattern = #"(<image\b[^>]*?\s(?:xlink:)?href\s*=\s*)(["'])learner-image\2"#
		guard let regex = try? NSRegularExpression(pattern: pattern) else { return svg }
		let range = NSRange(svg.startIndex..., in: svg)
		return regex.stringByReplacingMatches(in: svg, range: range, withTemplate: "$1$2\(NSRegularExpression.escapedTemplate(for: dataURI))$2")
	}
}

private extension View {
	@ViewBuilder func colorInvert(_ active: Bool) -> some View {
		if active { self.colorInvert().hueRotation(.degrees(180)) } else { self }
	}
}

struct ShowImageCard: View {
	let model: SessionModel
	let part: NativeViewPart
	@State private var image: UIImage?

	var body: some View {
		let output = part.output
		if part.state == "output-available", let snapshotId = output?["snapshotId"]?.stringValue {
			VStack(alignment: .leading, spacing: 6) {
				if let image {
					Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 10))
				} else {
					ProgressView().frame(maxWidth: .infinity, minHeight: 120)
				}
				if let caption = output?["caption"]?.stringValue {
					Text(caption).font(.callout).foregroundStyle(.secondary)
				}
			}
			.task(id: snapshotId) {
				if let snapshot = await model.imageSnapshot(snapshotId), let data = snapshot.bytes { image = UIImage(data: data) }
			}
		} else {
			ToolCallRow(tool: "show_image", part: part)
		}
	}
}

// MARK: - Practice

struct ProblemCard: View {
	let part: NativeViewPart

	var body: some View {
		CardBox {
			HStack {
				CardLabel(text: "Problem", systemImage: "puzzlepiece")
				if let mode = part.input?["mode"]?.stringValue { Text(mode).font(.caption).foregroundStyle(.secondary) }
			}
			MarkdownView(part.input?["statement"]?.stringValue ?? "")
		}
	}
}

struct ConcludeCard: View {
	let part: NativeViewPart

	var body: some View {
		let input = part.input
		let outcome = input?["outcome"]?.stringValue ?? ""
		let verdict = input?["verdict"]?.stringValue ?? ""
		let reveal = part["reveal"]?.stringValue ?? input?["solutionReveal"]?.stringValue ?? ""
		if outcome == "dismissed" && verdict.isEmpty && reveal.isEmpty {
			Text("PROBLEM DISCARDED").font(.caption.weight(.medium)).tracking(0.6).foregroundStyle(.secondary)
				.frame(maxWidth: .infinity)
		} else {
			CardBox(tint: outcome == "solved" ? .green : nil) {
				CardLabel(text: outcome.isEmpty ? "Concluded" : outcome, systemImage: "flag.checkered")
				if !verdict.isEmpty { MarkdownView(verdict) }
				if !reveal.isEmpty {
					CardLabel(text: "Model solution")
					MarkdownView(reveal)
				}
			}
		}
	}
}

// MARK: - Markers

struct MarkerCard: View {
	let part: NativeViewPart
	@State private var open = false

	var body: some View {
		switch part.type {
		case "data-graph-context":
			let picks = part.data?["propositions"]?.arrayValue ?? []
			let chains = part.data?["chains"]?.arrayValue ?? []
			DisclosureGroup(isExpanded: $open) {
				VStack(alignment: .leading, spacing: 6) {
					ForEach(Array(picks.enumerated()), id: \.offset) { _, pick in
						VStack(alignment: .leading, spacing: 2) {
							Text(pick["name"]?.stringValue ?? "").font(.callout.weight(.medium))
							Text(pick["statement"]?.stringValue ?? "").font(.callout).foregroundStyle(.secondary)
						}
					}
				}
				.padding(.top, 4)
			} label: {
				CardLabel(text: "Material · \(picks.count) proposition\(picks.count == 1 ? "" : "s")\(chains.isEmpty ? "" : " · \(chains.count) chain\(chains.count == 1 ? "" : "s")")", systemImage: "point.3.connected.trianglepath.dotted")
			}
			.tint(.secondary)
		case "data-compaction":
			PhaseDivider(title: "Context compacted")
		case "data-compaction-cut":
			DisclosureGroup(isExpanded: $open) {
				MarkdownView(part.data?["content"]?.stringValue ?? "", textStyle: .callout).foregroundStyle(.secondary)
			} label: {
				CardLabel(text: "Earlier messages summarized for the model", systemImage: "scissors")
			}
			.tint(.secondary)
		case "data-practice-thinking":
			let commit = part.data?["commit"]?.boolValue == true
			ThinkingQuote(label: commit ? "YOUR ANSWER" : "YOUR THINKING", text: part.data?["text"]?.stringValue ?? "")
		case "data-practice-next":
			HStack(spacing: 6) {
				Image(systemName: "arrow.right")
				Text("NEXT PROBLEM").tracking(0.6)
			}
			.font(.caption.weight(.medium)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
		default:
			EmptyView()
		}
	}
}

// MARK: - Plan

struct PlanBlockCard: View {
	let data: JSONValue?
	let model: SessionModel
	@State private var showPlan = false

	var body: some View {
		let nodes = data?["nodes"]?.arrayValue ?? []
		Button { showPlan = true } label: {
			CardBox {
				CardLabel(text: "Plan · \(nodes.count) step\(nodes.count == 1 ? "" : "s")", systemImage: "map")
				ForEach(Array(nodes.prefix(6).enumerated()), id: \.offset) { _, node in
					Label(node["title"]?.stringValue ?? "", systemImage: PlanDiagram.symbol(node["status"]?.stringValue))
						.font(.callout).foregroundStyle(.primary)
				}
				if nodes.count > 6 { Text("…and \(nodes.count - 6) more").font(.caption).foregroundStyle(.secondary) }
			}
		}
		.buttonStyle(.plain)
		.sheet(isPresented: $showPlan) { PlanSheet(model: model) }
	}
}

struct PlanSheet: View {
	let model: SessionModel
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		NavigationStack {
			ScrollView {
				if let plan = model.state?.plan {
					MermaidView(source: PlanDiagram.mermaid(plan))
						.padding()
				} else {
					ContentUnavailableView("No plan yet", systemImage: "map")
				}
			}
			.navigationTitle("Plan")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
		}
	}
}

enum PlanDiagram {
	static func symbol(_ status: String?) -> String {
		switch status {
		case "current": "largecircle.fill.circle"
		case "visited": "checkmark.circle"
		default: "circle"
		}
	}

	/// The live plan as a Mermaid flowchart (prerequisites point to dependants),
	/// coloured by derived status like the web's plan popup.
	static func mermaid(_ plan: NativePlan) -> String {
		var ids: [String: String] = [:]
		for (index, node) in plan.tree.nodes.enumerated() { ids[node.id] = "n\(index)" }
		var lines = ["graph TD"]
		for node in plan.tree.nodes {
			let label = node.title.replacingOccurrences(of: "\"", with: "'")
			let status = node.id == plan.current ? "current" : plan.visited.contains(node.id) ? "visited" : "upcoming"
			lines.append("  \(ids[node.id]!)[\"\(label)\"]:::\(status)")
		}
		for edge in plan.tree.edges {
			if let from = ids[edge.from], let to = ids[edge.to] { lines.append("  \(from) --> \(to)") }
		}
		lines.append("  classDef current fill:#fde68a,stroke:#d97706,color:#111;")
		lines.append("  classDef visited fill:#d1fae5,stroke:#059669,color:#111;")
		lines.append("  classDef upcoming fill:#f3f4f6,stroke:#9ca3af,color:#111;")
		return lines.joined(separator: "\n")
	}
}
