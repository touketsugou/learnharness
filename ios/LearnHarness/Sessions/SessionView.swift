import CoreTransferable
import LHAPI
import SwiftUI
import UniformTypeIdentifiers

/// One session: transcript + dock. Owns its SessionModel for its lifetime.
struct SessionView: View {
	let chatId: String
	@Environment(AppModel.self) private var app
	@State private var model: SessionModel?

	var body: some View {
		Group {
			if let model {
				SessionContent(model: model)
			} else {
				ProgressView()
			}
		}
		.task {
			guard model == nil, let client = app.client, let store = app.store else { return }
			let session = SessionModel(chatId: chatId, client: client, store: store, events: app.events)
			model = session
			session.start()
			if let opening = app.takeOpening(for: chatId) { await session.sendText(opening) }
		}
		.onDisappear { model?.stop() }
	}
}

private struct SessionContent: View {
	let model: SessionModel
	@State private var showPlan = false

	var body: some View {
		ScrollView {
			TranscriptList(model: model)
				.padding(.horizontal, 16)
				.padding(.vertical, 12)
				.frame(maxWidth: 820)
				.frame(maxWidth: .infinity)
		}
		.defaultScrollAnchor(.bottom)
		.defaultScrollAnchor(.bottom, for: .sizeChanges)
		.scrollDismissesKeyboard(.interactively)
		.safeAreaInset(edge: .bottom, spacing: 0) { SessionDock(model: model) }
		.navigationTitle(model.state?.title ?? "")
		.navigationBarTitleDisplayMode(.inline)
		.toolbar {
			ToolbarItemGroup(placement: .topBarTrailing) {
				ModelMenu(model: model)
				if model.state?.plan != nil {
					Button { showPlan = true } label: { Image(systemName: "map") }
						.accessibilityLabel("Plan")
				}
				if let title = model.state?.title {
					ShareLink(item: SessionMarkdown(title: title, load: model.markdownLoader), preview: SharePreview(title)) {
						Image(systemName: "square.and.arrow.up")
					}
					.accessibilityLabel("Share as Markdown")
				}
			}
		}
		.sheet(isPresented: $showPlan) { PlanSheet(model: model) }
	}
}

/// The session as Markdown (GET /api/chats/:id/markdown), fetched on share.
struct SessionMarkdown: Transferable {
	let title: String
	let load: @Sendable () async throws -> String

	static var transferRepresentation: some TransferRepresentation {
		DataRepresentation(exportedContentType: .utf8PlainText) { item in
			Data(try await item.load().utf8)
		}
		.suggestedFileName("LearnHarness session.md")
	}
}
