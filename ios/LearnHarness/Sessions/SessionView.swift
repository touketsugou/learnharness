import CoreTransferable
import LHAPI
import SwiftUI
import UniformTypeIdentifiers

/// One session: transcript + dock. Owns its SessionModel for its lifetime.
struct SessionView: View {
	let chatId: String
	@Environment(AppModel.self) private var app
	@State private var model: SessionModel?
	@State private var focus: String?

	var body: some View {
		Group {
			if let model {
				SessionContent(model: model, focus: $focus)
			} else {
				ProgressView()
			}
		}
		.task {
			// Back from another tab (which stopped the model): follow again,
			// and take a passage the graph asked for meanwhile.
			if let model {
				if let requested = app.takeMessageFocus(for: chatId) { focus = requested }
				model.start()
				return
			}
			guard let client = app.client, let store = app.store else { return }
			let session = SessionModel(chatId: chatId, client: client, store: store, events: app.events, drafts: app.drafts(for: chatId))
			focus = app.takeMessageFocus(for: chatId)
			model = session
			session.start()
			if let opening = app.takeOpening(for: chatId) { await session.sendText(opening) }
		}
		.onDisappear { model?.stop() }
	}
}

private struct SessionContent: View {
	let model: SessionModel
	/// A native message to bring into view once the transcript loads (from the graph).
	@Binding var focus: String?
	@State private var showPlan = false
	@State private var position = ScrollPosition()
	@State private var atTop = false

	var body: some View {
		ScrollViewReader { proxy in
			ScrollView {
				TranscriptList(model: model)
					.padding(.horizontal, 16)
					.padding(.vertical, TranscriptList.verticalPadding)
					.frame(maxWidth: 820)
					.frame(maxWidth: .infinity)
			}
			.onChange(of: model.view?.messages.count ?? 0, initial: true) { scrollToFocus(proxy) }
			.onChange(of: focus) { scrollToFocus(proxy) }
			.onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top < 1 } action: { _, top in
				atTop = top
			}
			// A transcript shorter than the screen can't scroll: it shows more
			// until it fills the screen.
			.onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height - $0.contentSize.height } action: { _, room in
				if room > 0 { model.showEarlier() }
			}
			.onScrollPhaseChange { _, phase in
				if phase == .idle, atTop { showEarlier() }
			}
		}
		.scrollPosition($position)
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

extension SessionContent {
	/// Scrolled to the top and stopped: the page before joins the transcript.
	/// The scroll view would keep its offset and show the new page's top, so
	/// it scrolls to the row that was on top, where it was.
	private func showEarlier() {
		if model.showEarlier() { position.scrollTo(id: EarlierMark.id, anchor: .top) }
	}

	private func scrollToFocus(_ proxy: ScrollViewProxy) {
		guard let messageId = focus, let messages = model.view?.messages, !messages.isEmpty else { return }
		focus = nil
		guard let target = SessionAnchor.target(forNativeMessage: messageId, in: messages) else { return }
		model.reveal(partID: target.partID)
		// The message row first, then the exact prose part inside it.
		Task { @MainActor in
			try? await Task.sleep(for: .milliseconds(150))
			proxy.scrollTo(target.messageID, anchor: .top)
			try? await Task.sleep(for: .milliseconds(150))
			withAnimation { proxy.scrollTo(target.partID, anchor: .top) }
		}
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
