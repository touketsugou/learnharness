import LHAPI
import SwiftUI

/// Providers (web KeysSection): model API keys and the custom endpoint,
/// subscriptions, Claude Code, the Deepgram key and the search keys.
/// Plaintext never comes back; rows show the masked tail and length.
struct ProvidersView: View {
	let model: SettingsModel
	@State private var editing: KeyEditTarget?
	@State private var connecting: SubscriptionProvider?

	var body: some View {
		List {
			if let keys = model.keys {
				let groups = KeyTable.classify(keys.keys, providers: keys.providers)
				Section("Model API keys") {
					ForEach(groups.providerRows) { status in
						keyRow(status, label: KeyTable.providerLabel(status.id, providers: keys.providers) ?? status.info?.label ?? status.id)
					}
					if let custom = model.custom, custom.isConfigured {
						NavigationLink {
							CustomEndpointView(model: model)
						} label: {
							SettingLabel(title: "Custom endpoint", hint: custom.summary)
						}
					}
					if keys.providers != nil {
						NavigationLink {
							AddProviderList(model: model, addable: groups.addable + (model.custom?.isConfigured == true ? [] : [KeyTable.customProvider]))
						} label: {
							Label("Add a provider", systemImage: "plus")
						}
					}
					ForEach(groups.unknownRows) { status in
						LabeledContent(status.id, value: status.masked ?? "")
							.font(.footnote.monospaced())
							.opacity(0.4)
					}
				}
				Section("Subscriptions") {
					ForEach(SubscriptionProvider.all) { provider in
						let status = model.subscription(provider.providerId)
						HStack {
							Text(provider.label)
							Spacer()
							Button(status.connectionId == nil ? "Connect" : "Manage…") { connecting = provider }
								.buttonStyle(.bordered)
								.controlSize(.small)
								.disabled(!status.available || model.anySubscriptionPending)
						}
					}
				}
				Section("External CLI") {
					ClaudeCodeRows(model: model)
				}
				Section {
					ForEach(groups.toolRows.filter { $0.id == KeyTable.dictationID }) { keyRow($0, label: $0.info?.label ?? $0.id) }
				} header: {
					Text("Dictation")
				} footer: {
					Text("Create a [Deepgram API key](https://console.deepgram.com/) with the Member role or higher, then add it above.")
				}
				Section("Search") {
					ForEach(groups.toolRows.filter { $0.id != KeyTable.dictationID }) { keyRow($0, label: $0.info?.label ?? $0.id) }
				}
			} else if let error = model.keysError {
				ContentUnavailableView("Couldn’t load keys", systemImage: "exclamationmark.triangle", description: Text(error))
			} else {
				ProgressView().frame(maxWidth: .infinity)
			}
		}
		.navigationTitle("Providers")
		.refreshable { await reload() }
		.task { await reload() }
		.sheet(item: $editing) { target in
			KeyEditSheet(target: target, model: model)
		}
		.sheet(item: $connecting) { provider in
			SubscriptionSheet(model: model, provider: provider)
		}
	}

	private func reload() async {
		async let subscriptions: Void = model.reloadSubscriptions()
		await model.reloadKeys()
		await subscriptions
	}

	/// Env-owned rows are dimmed and read-only (a paste box would mislead).
	private func keyRow(_ status: AuthKeyStatus, label: String) -> some View {
		Button {
			editing = KeyEditTarget(id: status.id, label: label, docsUrl: status.info?.docsUrl, deletable: status.present && status.source == "file")
		} label: {
			LabeledContent(label) {
				Text(KeyTable.statusLine(status)).font(.footnote.monospaced())
			}
		}
		.tint(.primary)
		.disabled(status.envOwned)
		.opacity(status.envOwned ? 0.4 : 1)
	}
}

struct KeyEditTarget: Identifiable {
	/// The key's id (its environment variable name).
	var id: String
	var label: String
	var docsUrl: String?
	/// A file-stored value can be deleted.
	var deletable: Bool
}

/// Paste a key, Save; Delete for a stored one. Saves take effect immediately.
struct KeyEditSheet: View {
	let target: KeyEditTarget
	let model: SettingsModel
	var onSaved: () -> Void = {}
	@Environment(\.dismiss) private var dismiss
	@State private var value = ""
	@State private var busy = false
	@State private var error: String?
	@FocusState private var focused: Bool

	var body: some View {
		NavigationStack {
			Form {
				Section {
					SecureField("Paste key…", text: $value)
						.focused($focused)
						.onAppear { focused = true }
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
						.font(.body.monospaced())
						.onSubmit { Task { await save() } }
				} footer: {
					VStack(alignment: .leading, spacing: 6) {
						if let error { Text(error).foregroundStyle(.red) }
						if let docs = target.docsUrl, let url = URL(string: docs) {
							Link("Get a key ↗", destination: url)
						}
					}
				}
				if target.deletable {
					Section {
						Button("Delete Key", role: .destructive) {
							Task {
								busy = true
								await model.deleteKey(target.id)
								dismiss()
							}
						}
						.disabled(busy)
					}
				}
			}
			.navigationTitle(target.label)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Cancel") { dismiss() }.disabled(busy)
				}
				ToolbarItem(placement: .confirmationAction) {
					if busy {
						ProgressView()
					} else {
						Button("Save") { Task { await save() } }
							.disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
					}
				}
			}
		}
		.presentationDetents([.medium])
		.interactiveDismissDisabled(busy)
	}

	private func save() async {
		guard !busy, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
		busy = true
		error = await model.saveKey(target.id, value: value)
		busy = false
		if error == nil {
			dismiss()
			onSaved()
		}
	}
}

/// The providers without a stored key (plus the custom endpoint while
/// unconfigured), searchable; picking one opens its key sheet.
private struct AddProviderList: View {
	let model: SettingsModel
	let addable: [ProviderKeyInfo]
	@Environment(\.dismiss) private var dismiss
	@State private var query = ""
	@State private var editing: KeyEditTarget?

	var body: some View {
		List {
			ForEach(filtered) { provider in
				if provider.id == KeyTable.customProvider.id {
					NavigationLink(provider.label) { CustomEndpointView(model: model) }
				} else {
					Button(provider.label) {
						editing = KeyEditTarget(id: provider.envVar, label: provider.label, docsUrl: nil, deletable: false)
					}
					.tint(.primary)
				}
			}
			if filtered.isEmpty { Text("No providers match.").foregroundStyle(.secondary) }
		}
		.searchable(text: $query, prompt: "Search providers")
		.navigationTitle("Add a Provider")
		.navigationBarTitleDisplayMode(.inline)
		.sheet(item: $editing) { target in
			KeyEditSheet(target: target, model: model) { dismiss() }
		}
	}

	private var filtered: [ProviderKeyInfo] {
		let terms = query.lowercased().split(separator: " ")
		let sorted = addable.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
		guard !terms.isEmpty else { return sorted }
		return sorted.filter { provider in
			let haystack = "\(provider.label) \(provider.id) \(provider.envVar)".lowercased()
			return terms.allSatisfy { haystack.contains($0) }
		}
	}
}

/// Claude Code: the switch (claudeCode settings section) and, when on, the
/// installation check. Never reads authentication or makes a model call.
private struct ClaudeCodeRows: View {
	let model: SettingsModel
	@State private var status: ClaudeCodeStatus?
	@State private var checking = false
	@State private var saving = false

	private var enabled: Bool { model.section("claudeCode")["enabled"]?.boolValue == true }

	var body: some View {
		Toggle("Claude Code", isOn: Binding(get: { enabled }, set: { next in
			Task {
				saving = true
				var section = model.section("claudeCode")
				section["enabled"] = .bool(next)
				await model.write("claudeCode", section)
				saving = false
				await check()
			}
		}))
		.disabled(saving || model.record == nil)
		.task(id: enabled) { await check() }
		if enabled {
			HStack {
				Text(checking ? "Checking…" : status?.label ?? "Version could not be checked")
					.font(.footnote)
					.foregroundStyle(.secondary)
				Spacer()
				Button("Check Again") { Task { await check() } }
					.buttonStyle(.bordered)
					.controlSize(.small)
					.disabled(checking)
			}
			VStack(alignment: .leading, spacing: 6) {
				Text("**Install and authenticate Claude Code in your terminal, then select a Claude Code model here.** LearnHarness starts it when needed—no background process required.")
				Text("Checks installation/version only—not authentication, model access, or quota. Claude Code controls billing. Requires v\(status?.minimumVersion ?? "2.1.259")+. [Setup ↗](https://code.claude.com/docs/en/setup)")
				Text("Verify AI claims independently—they may be inaccurate, incomplete, misleading, or outdated.")
			}
			.font(.footnote)
			.foregroundStyle(.secondary)
		}
	}

	private func check() async {
		guard enabled else { status = nil; return }
		checking = true
		status = try? await model.client.claudeCodeStatus()
		checking = false
	}
}
