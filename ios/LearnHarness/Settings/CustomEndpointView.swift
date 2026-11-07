import LHAPI
import SwiftUI

/// The custom OpenAI-compatible endpoint (web CustomEndpointEditor): base
/// URL + key → Connect (validate, discover, register); the per-model limit
/// pins save separately. Every write carries the status revision (If-Match).
struct CustomEndpointView: View {
	let model: SettingsModel
	@Environment(\.dismiss) private var dismiss

	@State private var loaded: CustomProviderStatus?
	@State private var loadFailed = false
	@State private var revision = ""
	@State private var authMode = "keyless"
	@State private var keySource = "none"
	@State private var keyPresent = false
	@State private var keyReuseRequired = false
	@State private var authLoading = false
	@State private var reuseKey = false
	@State private var baseUrl = ""
	@State private var key = ""
	@State private var keyTouched = false
	@State private var manualModels = ""
	@State private var busy = false
	@State private var error: String?
	@State private var drafts: [String: CustomPinDraft] = [:]
	@State private var baseline: [String: CustomModelOverride] = [:]
	@State private var pinsBusy = false
	@State private var pinsError: String?

	var body: some View {
		Form {
			if let loaded {
				connection(loaded)
				if loaded.isConfigured, !loaded.models.isEmpty { limits(loaded) }
				if error != nil || pinsError != nil {
					Section {
						Button("Reload Configuration") { Task { await load() } }
					}
				}
			} else if loadFailed {
				ContentUnavailableView {
					Label("Unable to load custom configuration.", systemImage: "exclamationmark.triangle")
				} actions: {
					Button("Retry") { Task { await load() } }.buttonStyle(.bordered)
				}
			} else {
				ProgressView().frame(maxWidth: .infinity)
			}
		}
		.navigationTitle("Custom Endpoint")
		.navigationBarTitleDisplayMode(.inline)
		.task { if loaded == nil { await load() } }
		.onChange(of: authMode) { _, mode in
			reuseKey = false
			if mode == "apiKey" { Task { await inspectKey() } }
		}
	}

	// MARK: Connection

	@ViewBuilder private func connection(_ status: CustomProviderStatus) -> some View {
		Section {
			TextField("Base URL, e.g. http://localhost:11434/v1", text: $baseUrl)
				.keyboardType(.URL)
				.textInputAutocapitalization(.never)
				.autocorrectionDisabled()
				.font(.body.monospaced())
			TextField("Model IDs, comma-separated — optional, needed when the endpoint has no /models list", text: $manualModels, axis: .vertical)
				.textInputAutocapitalization(.never)
				.autocorrectionDisabled()
				.font(.body.monospaced())
			Picker("Authentication", selection: $authMode) {
				Text("Keyless").tag("keyless")
				Text("API key").tag("apiKey")
			}
			.disabled(busy || pinsBusy)
			if authMode == "apiKey" {
				SecureField(keyPresent ? "Leave blank to keep effective key" : "API key", text: Binding(get: { key }, set: { text in
					key = text
					keyTouched = true
					// The web's rule: clearing the key returns to keyless.
					if text.trimmingCharacters(in: .whitespaces).isEmpty { authMode = "keyless" }
				}))
				.textInputAutocapitalization(.never)
				.autocorrectionDisabled()
				.disabled(busy || pinsBusy || keySource == "env")
				if keySource == "env" {
					Text("Environment supplies the effective key. Change the environment to replace it.")
						.font(.footnote).foregroundStyle(.secondary)
				}
				if keyPresent, changedTarget || keyReuseRequired {
					Toggle("Allow reuse of the effective existing key for this URL", isOn: $reuseKey)
						.font(.footnote)
				}
			}
		} header: {
			Text("Connection")
		} footer: {
			VStack(alignment: .leading, spacing: 6) {
				if let error { Text(error).foregroundStyle(.red) }
				Text("Reasoning support is a capability declaration. The effort picker’s Off may not disable a custom backend’s default thinking.")
			}
		}
		Section {
			Button {
				Task { await connect() }
			} label: {
				HStack {
					Text(busy ? "Connecting…" : "Connect")
					if busy { Spacer(); ProgressView() }
				}
			}
			.disabled(busy || pinsBusy || !canConnect)
			if status.isConfigured {
				Button("Disconnect", role: .destructive) { Task { await disconnect() } }
					.disabled(busy || pinsBusy)
			}
		}
	}

	private var changedTarget: Bool {
		normalizedEndpointURL(baseUrl) != normalizedEndpointURL(loaded?.baseUrl ?? "")
	}

	private var canConnect: Bool {
		guard !baseUrl.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
		if authMode == "keyless" { return true }
		if authLoading { return false }
		let typed = !key.trimmingCharacters(in: .whitespaces).isEmpty && keySource != "env"
		let reusable = keyPresent && (!(changedTarget || keyReuseRequired) || reuseKey)
		return typed || reusable
	}

	// MARK: Model limits

	@ViewBuilder private func limits(_ status: CustomProviderStatus) -> some View {
		Section {
			ForEach(status.models) { item in
				PinRow(model: item, draft: Binding(get: { drafts[item.id] ?? CustomPinDraft(status.overrides[item.id]) }, set: { drafts[item.id] = $0 }))
					.disabled(pinsBusy)
			}
			Button {
				Task { await savePins() }
			} label: {
				HStack {
					Text(pinsBusy ? "Saving…" : "Save Limits")
					if pinsBusy { Spacer(); ProgressView() }
				}
			}
			.disabled(pinsBusy || busy || CustomPinDraft.payload(drafts) == baseline)
		} header: {
			Text("Model limits")
		} footer: {
			VStack(alignment: .leading, spacing: 6) {
				if let pinsError { Text(pinsError).foregroundStyle(.red) }
				Text("Budget pins do not resize backend context. Blank uses reported limits, then fallback (8192 context / 4096 output). Custom pricing is unknown.")
			}
		}
	}

	// MARK: Actions

	private func load() async {
		do {
			seed(try await model.client.customProvider())
			loadFailed = false
			error = nil
			pinsError = nil
		} catch {
			loadFailed = loaded == nil
		}
	}

	private func seed(_ status: CustomProviderStatus) {
		loaded = status
		revision = status.revision
		authMode = status.authMode
		keySource = status.keySource
		keyPresent = status.keyPresent
		keyReuseRequired = status.keyReuseRequired
		baseUrl = status.baseUrl
		manualModels = status.manualModels.joined(separator: ", ")
		key = ""
		keyTouched = false
		reuseKey = false
		drafts = CustomPinDraft.drafts(status.models, status.overrides)
		baseline = CustomPinDraft.payload(drafts)
	}

	private func inspectKey() async {
		authLoading = true
		defer { authLoading = false }
		do {
			let status = try await model.client.customProvider(inspectKey: true)
			keySource = status.keySource
			keyPresent = status.keyPresent
			keyReuseRequired = status.keyReuseRequired
			if status.keySource == "env" { key = "" }
		} catch {
			self.error = "Unable to inspect effective key. Reload configuration and retry."
		}
	}

	private func connect() async {
		guard !busy, !pinsBusy, canConnect else { return }
		busy = true
		error = nil
		let typed = authMode == "apiKey" && keyTouched && !key.trimmingCharacters(in: .whitespaces).isEmpty && keySource != "env"
		do {
			try await model.client.connectCustomProvider(
				CustomConnectRequest(baseUrl: baseUrl, authMode: authMode, reuseKey: reuseKey, manualModels: manualModels, key: typed ? key : nil),
				revision: revision
			)
			await model.reloadKeys()
			await model.reloadCatalog()
			busy = false
			dismiss()
		} catch {
			self.error = SettingsModel.message(error)
			busy = false
		}
	}

	private func disconnect() async {
		busy = true
		error = nil
		do {
			try await model.client.disconnectCustomProvider(revision: revision)
			await model.reloadKeys()
			await model.reloadCatalog()
			busy = false
			dismiss()
		} catch {
			self.error = SettingsModel.message(error)
			busy = false
		}
	}

	private func savePins() async {
		guard let loaded, !pinsBusy, !busy else { return }
		pinsBusy = true
		pinsError = nil
		do {
			let saved = try await model.client.saveCustomPins(CustomPinDraft.payload(drafts), revision: revision)
			revision = saved.revision
			drafts = CustomPinDraft.drafts(loaded.models, saved.overrides)
			baseline = CustomPinDraft.payload(drafts)
			await model.reloadCustom()
			await model.reloadCatalog()
		} catch {
			pinsError = SettingsModel.message(error)
		}
		pinsBusy = false
	}
}

/// One discovered model: context and max-output pins, reasoning support.
private struct PinRow: View {
	let model: CustomModel
	@Binding var draft: CustomPinDraft

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(model.id).font(.footnote.monospaced())
			Text(source).font(.caption).foregroundStyle(.secondary)
			HStack {
				TextField(String(model.context ?? CustomProviderStatus.defaultContextWindow), text: $draft.context)
					.keyboardType(.numberPad)
					.accessibilityLabel("\(model.id) context window in tokens")
				TextField(String(model.maxTokens ?? CustomProviderStatus.defaultMaxTokens), text: $draft.maxTokens)
					.keyboardType(.numberPad)
					.accessibilityLabel("\(model.id) max output tokens")
			}
			.textFieldStyle(.roundedBorder)
			.font(.footnote.monospaced())
			Picker("Reasoning effort", selection: $draft.reasoning) {
				Text("Use reported").tag("")
				Text("Supported").tag("on")
				Text("Not supported").tag("off")
			}
			.font(.footnote)
		}
	}

	private var source: String {
		let context = !draft.context.trimmingCharacters(in: .whitespaces).isEmpty ? "user pin"
			: model.context.map { "reported \($0)" } ?? "fallback \(CustomProviderStatus.defaultContextWindow)"
		let output = !draft.maxTokens.trimmingCharacters(in: .whitespaces).isEmpty ? "user pin"
			: model.maxTokens.map { "reported \($0)" } ?? "fallback \(CustomProviderStatus.defaultMaxTokens)"
		return "Context: \(context) · Output: \(output)"
	}
}
