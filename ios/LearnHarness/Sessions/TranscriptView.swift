import LHAPI
import LHRender
import SwiftUI

/// Read-only transcript scaffold (Phase D): loads the projected view, follows
/// a running turn's stream, and falls back to the offline copy.
struct TranscriptView: View {
	let chatId: String
	@Environment(AppModel.self) private var model
	@State private var view: NativeSessionView?
	@State private var offline = false
	@State private var error: String?

	var body: some View {
		ScrollView {
			LazyVStack(alignment: .leading, spacing: 16) {
				if offline {
					Label("Offline — read-only copy", systemImage: "wifi.slash")
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
				ForEach(view?.messages ?? []) { message in
					MessageScaffold(message: message)
				}
				if let state = view?.state, state.status == .running {
					HStack(spacing: 8) {
						ProgressView()
						Text(state.activity ?? "Thinking…").foregroundStyle(.secondary)
					}
				}
				if let failure = view?.state.failure {
					Label(failure.message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
				}
			}
			.padding()
		}
		.navigationTitle(view?.state.title ?? "")
		.navigationBarTitleDisplayMode(.inline)
		.overlay {
			if view == nil, let error {
				ContentUnavailableView("Couldn't open the session", systemImage: "exclamationmark.triangle", description: Text(error))
			} else if view == nil {
				ProgressView()
			}
		}
		.task { await follow() }
	}

	private func follow() async {
		guard let client = model.client, let store = model.store else { return }
		do {
			for try await frame in client.nativeStream(chatId) {
				guard let next = NativeViewReducer.apply(frame, to: view) else { continue }
				view = next
				offline = false
				if case .settled = frame { try? await store.saveView(next) }
			}
		} catch is CancellationError {
		} catch APIError.transport {
			if let cached = await store.loadView(chatId: chatId) {
				view = cached
				offline = true
			} else {
				error = "The server can't be reached and this session has no offline copy."
			}
		} catch {
			self.error = (error as? APIError)?.message ?? error.localizedDescription
		}
	}
}

private struct MessageScaffold: View {
	let message: NativeViewMessage

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			ForEach(Array(message.parts.enumerated()), id: \.offset) { _, part in
				switch part.type {
				case "text":
					if message.role == .user {
						Text(part.text ?? "")
							.padding(10)
							.background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.12)))
							.frame(maxWidth: .infinity, alignment: .trailing)
					} else {
						MarkdownView(part.text ?? "")
					}
				case "reasoning":
					if let text = part.text, !text.isEmpty {
						DisclosureGroup("Thinking") { MarkdownView(text, textStyle: .callout).foregroundStyle(.secondary) }
							.font(.callout)
					}
				case "step-start":
					EmptyView()
				case "tool-problem":
					MarkdownView(part.input?["statement"]?.stringValue ?? "")
						.padding(12)
						.background(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
				case "tool-conclude":
					if let reveal = part["reveal"]?.stringValue, !reveal.isEmpty {
						MarkdownView(reveal)
							.padding(12)
							.background(RoundedRectangle(cornerRadius: 12).fill(Color.green.opacity(0.08)))
					}
				default:
					Label(part.toolName ?? part.type, systemImage: part.toolName == nil ? "square.dashed" : "wrench.and.screwdriver")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
		}
	}
}
