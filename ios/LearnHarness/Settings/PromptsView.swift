import LHAPI
import SwiftUI

/// System prompts: Teacher, Prober, Practice, then Shared. A row's switch
/// needs a saved override ("your version"); the text is edited on its own
/// page. The switches live in the agent section; the text in its own files.
struct PromptsView: View {
	let model: SettingsModel
	@State private var store: PromptStore?

	var body: some View {
		List {
			if let store, let view = store.view {
				ForEach(view.sections) { section in
					Section(section.label) {
						ForEach(section.rows) { row in
							NavigationLink {
								PromptDetailView(model: model, store: store, path: row.segment.path)
							} label: {
								HStack {
									SettingLabel(title: row.segment.path, hint: hint(row))
									Spacer()
									Toggle("", isOn: Binding(get: { row.segment.enabled }, set: { on in
										Task {
											await model.write("agent", AgentCompose.promptSwitch(model.section("agent"), path: row.segment.path, on: on))
											await store.reload()
										}
									}))
									.labelsHidden()
									.disabled(row.segment.overrideText == nil)
									.opacity(row.segment.overrideText == nil ? 0.4 : 1)
								}
							}
						}
					}
				}
			} else if store?.failed == true {
				ContentUnavailableView("Couldn’t load prompts", systemImage: "exclamationmark.triangle")
			} else {
				ProgressView().frame(maxWidth: .infinity)
			}
		}
		.navigationTitle("Prompts")
		.refreshable { await store?.reload() }
		.task {
			if store == nil { store = PromptStore(client: model.client) }
			await store?.reload()
		}
	}

	private func hint(_ row: PromptView.Row) -> String? {
		let parts = [row.usageHint, row.segment.enabled ? promptInUseHint : nil].compactMap(\.self)
		return parts.isEmpty ? nil : parts.joined(separator: " · ")
	}
}

/// The segment view, shared by the list and the pushed detail page.
@MainActor
@Observable
final class PromptStore {
	private(set) var view: PromptView?
	private(set) var failed = false
	private let client: APIClient

	init(client: APIClient) { self.client = client }

	func reload() async {
		do {
			view = try await client.promptSegments()
			failed = false
		} catch {
			failed = view == nil
		}
	}
}

/// One segment: use-my-version switch, the original (read-only), your
/// version in a full-height editor; Save and Delete.
private struct PromptDetailView: View {
	let model: SettingsModel
	let store: PromptStore
	let path: String
	/// The editor's text, re-seeded whenever the stored override changes.
	@State private var text = ""
	@State private var status: String?
	@State private var busy = false
	@State private var showOriginal = false

	private var segment: PromptSegment? {
		guard let view = store.view else { return nil }
		return (view.teacher + view.prober + view.practice).first { $0.path == path }
	}

	var body: some View {
		Form {
			if let segment {
				Section {
					Toggle("Use my version", isOn: Binding(get: { segment.enabled }, set: { on in
						Task {
							await model.write("agent", AgentCompose.promptSwitch(model.section("agent"), path: path, on: on))
							await store.reload()
						}
					}))
					.disabled(segment.overrideText == nil || busy)
				} footer: {
					if segment.enabled { Text(promptInUseHint) }
				}
				Section {
					DisclosureGroup("Original", isExpanded: $showOriginal) {
						Text(segment.sourceText)
							.font(.footnote)
							.foregroundStyle(.secondary)
							.textSelection(.enabled)
					}
				}
				Section {
					TextEditor(text: $text)
						.font(.footnote)
						.frame(minHeight: 320)
						.overlay(alignment: .topLeading) {
							if text.isEmpty {
								Text("Add your own instructions…")
									.font(.footnote)
									.foregroundStyle(.tertiary)
									.padding(.top, 8)
									.padding(.leading, 5)
									.allowsHitTesting(false)
							}
						}
				} header: {
					Text("Your version")
				} footer: {
					if let status { Text(status) }
				}
				if segment.overrideText != nil {
					Section {
						Button("Delete My Version", role: .destructive) { Task { await delete(segment) } }
							.disabled(busy)
					}
				}
			} else {
				ProgressView().frame(maxWidth: .infinity)
			}
		}
		.navigationTitle((path as NSString).lastPathComponent)
		.navigationBarTitleDisplayMode(.inline)
		.onChange(of: segment?.overrideText, initial: true) { text = segment?.overrideText ?? "" }
		.toolbar {
			ToolbarItem(placement: .confirmationAction) {
				if let segment {
					Button("Save") { Task { await save(segment, text: text) } }
						.disabled(text == (segment.overrideText ?? "") || busy)
				}
			}
		}
	}

	/// Saving switches the override on (the web's rhythm).
	private func save(_ segment: PromptSegment, text: String) async {
		busy = true
		status = nil
		do {
			try await model.client.savePrompt(path, text: text)
			if model.section("agent")["prompts"]?[path]?.boolValue != true {
				await model.write("agent", AgentCompose.promptSwitch(model.section("agent"), path: path, on: true))
			}
			await store.reload()
			status = "Saved"
		} catch {
			status = "Save failed: \(SettingsModel.message(error))"
		}
		busy = false
	}

	private func delete(_ segment: PromptSegment) async {
		busy = true
		status = nil
		do {
			try await model.client.deletePrompt(path)
			if model.section("agent")["prompts"]?[path]?.boolValue == true {
				await model.write("agent", AgentCompose.promptSwitch(model.section("agent"), path: path, on: false))
			}
			await store.reload()
			status = "Deleted"
		} catch {
			status = "Delete failed: \(SettingsModel.message(error))"
		}
		busy = false
	}
}
