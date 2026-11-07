import LHAPI
import SafariServices
import SwiftUI
import UIKit

/// One subscription connection (web NativeSubscriptionUIProvider's dialog):
/// the privacy notice, then sign-in with the device code and the provider's
/// page in an in-app Safari sheet; once connected, background use and
/// disconnect. Status updates arrive through `subscriptions-changed`.
struct SubscriptionSheet: View {
	let model: SettingsModel
	let provider: SubscriptionProvider
	@Environment(\.dismiss) private var dismiss

	private enum Stage { case notice, connection, manage }

	@State private var stage: Stage = .notice
	@State private var confirmDisconnect = false
	@State private var background = true
	@State private var backgroundDirty = false
	@State private var promptValue = ""
	@State private var signingIn = false
	@State private var controlling = false
	@State private var error: String?
	@State private var safari: URL?
	@State private var copied = false

	private var status: SubscriptionStatus { model.subscription(provider.providerId) }
	private var busy: Bool { controlling || status.committing == true }
	private var managing: Bool { stage == .manage }

	var body: some View {
		NavigationStack {
			Form {
				if confirmDisconnect {
					Section {
						Text("Disconnect \(provider.label)?").font(.headline).foregroundStyle(.red)
						Text(provider.disconnectCopy).font(.footnote).foregroundStyle(.secondary)
					}
				} else if stage == .notice {
					Section {
						Text(provider.notice).font(.footnote).foregroundStyle(.secondary)
						if provider.providerId == "github-copilot" {
							Text(SubscriptionProvider.copilotPolicyNotice).font(.footnote).foregroundStyle(.secondary)
						}
					}
				} else {
					Section {
						Toggle(isOn: Binding(get: { managing ? status.allowBackgroundUse : background }, set: setBackground)) {
							SettingLabel(title: "Allow background use", hint: SubscriptionProvider.backgroundHint)
						}
						.disabled(busy || signingIn || status.pending || !status.available)
					} footer: {
						if !status.available {
							Text("Subscription sign-in isn’t available on this server. API-key connections remain available.")
						}
					}
					if stage == .connection, let interaction = status.interaction {
						interactionSection(interaction)
					}
				}
				if let message = error ?? status.error {
					Section { Text(message).font(.footnote).foregroundStyle(.red) }
				}
				actions
			}
			.navigationTitle(provider.label)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button(confirmDisconnect || !managing ? "Cancel" : "Close") { close() }
						.disabled(busy)
				}
			}
		}
		.interactiveDismissDisabled(busy || signingIn || status.pending)
		.onAppear {
			background = status.allowBackgroundUse
			stage = status.connectionId == nil ? .notice : .manage
		}
		.onChange(of: status.interaction?.prompt?.id) { promptValue = "" }
		.sheet(item: Binding(get: { safari.map(SafariTarget.init) }, set: { if $0 == nil { safari = nil } })) { target in
			SafariView(url: target.url).ignoresSafeArea()
		}
	}

	// MARK: Sign-in progress

	@ViewBuilder private func interactionSection(_ interaction: SubscriptionInteraction) -> some View {
		Section {
			if let progress = interaction.progress {
				Text(progress).font(.footnote).foregroundStyle(.secondary)
			}
			if let code = interaction.userCode {
				LabeledContent("Device code") {
					Button {
						UIPasteboard.general.string = code
						copied = true
					} label: {
						Label(code, systemImage: copied ? "checkmark" : "doc.on.doc")
							.font(.body.monospaced())
					}
				}
			}
			if let browser = interaction.browser {
				Button("Open Browser", systemImage: "safari") { Task { await openBrowser(interaction, actionId: browser.id) } }
					.disabled(busy)
			}
			if let prompt = interaction.prompt {
				promptField(prompt, attemptId: interaction.attemptId)
			}
		} footer: {
			if interaction.userCode != nil, interaction.browser != nil {
				Text("Opening the browser copies the code; paste it on the sign-in page, then close the page to return.")
			}
		}
	}

	@ViewBuilder private func promptField(_ prompt: SubscriptionPrompt, attemptId: String) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(prompt.message).font(.footnote)
			if prompt.type == "select" {
				Picker("Choose", selection: $promptValue) {
					Text("Select…").tag("")
					ForEach(prompt.options ?? []) { option in Text(option.label).tag(option.id) }
				}
			} else if prompt.type == "secret" {
				SecureField(prompt.placeholder ?? "", text: $promptValue)
			} else {
				TextField(prompt.placeholder ?? "", text: $promptValue)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
			}
			Button("Continue") {
				Task {
					do {
						try await model.client.subscriptionControl(provider.providerId, op: "respond", fields: [
							"attemptId": .string(attemptId), "promptId": .string(prompt.id), "value": .string(promptValue),
						])
					} catch {
						self.error = "The connection could not be changed. Try again."
					}
				}
			}
			.disabled(busy || (prompt.type == "select" && promptValue.isEmpty))
		}
	}

	// MARK: Footer actions

	@ViewBuilder private var actions: some View {
		Section {
			if confirmDisconnect {
				Button("Disconnect", role: .destructive) { control(close: true) { try await op("disconnect") } }
					.disabled(busy)
			} else if stage == .notice {
				Button("Continue") { stage = .connection }
					.disabled(!status.available || signingIn)
			} else if stage == .connection {
				Button {
					Task { await login() }
				} label: {
					HStack {
						Text("Connect")
						if signingIn || status.pending { Spacer(); ProgressView() }
					}
				}
				.disabled(!status.available || signingIn || status.pending)
			} else {
				if status.connectionId != nil, status.available, !status.connected, status.error != nil, !status.pending {
					Button("Retry") { control { try await op("retry") } }.disabled(busy || signingIn)
					Button("Sign In Again") { beginSignIn() }.disabled(!status.available || busy || signingIn)
				}
				if status.connectionId != nil, !status.pending {
					Button("Disconnect", role: .destructive) { confirmDisconnect = true }
						.disabled(busy || signingIn)
				}
			}
		}
	}

	// MARK: Actions

	private func setBackground(_ enabled: Bool) {
		background = enabled
		if managing {
			control { try await op("consent", ["enabled": .bool(enabled)]) }
		} else {
			backgroundDirty = true
		}
	}

	private func beginSignIn() {
		error = nil
		confirmDisconnect = false
		background = status.allowBackgroundUse
		backgroundDirty = false
		stage = .notice
	}

	/// The login call returns when sign-in completes; progress (code,
	/// browser, prompts) arrives through status updates meanwhile.
	private func login() async {
		guard !signingIn, status.available else { return }
		signingIn = true
		error = nil
		let fields: [String: JSONValue] = backgroundDirty ? ["enabled": .bool(background)] : [:]
		let refresher = Task {
			while !Task.isCancelled {
				await model.reloadSubscriptions()
				try? await Task.sleep(for: .seconds(2))
			}
		}
		do {
			try await model.client.subscriptionControl(provider.providerId, op: "login", fields: fields, timeout: 900)
			refresher.cancel()
			await model.reloadSubscriptions()
			await model.reloadCatalog()
			signingIn = false
			dismiss()
		} catch {
			refresher.cancel()
			await model.reloadSubscriptions()
			signingIn = false
			self.error = "Sign-in did not complete. Try connecting again."
		}
	}

	private func openBrowser(_ interaction: SubscriptionInteraction, actionId: String) async {
		if let code = interaction.userCode {
			UIPasteboard.general.string = code
			copied = true
		}
		do {
			guard let action = try await model.client.subscriptionControl(provider.providerId, op: "open", fields: [
				"attemptId": .string(interaction.attemptId), "actionId": .string(actionId),
			]) else { throw APIError.decoding("No sign-in page.") }
			safari = try await model.client.subscriptionBrowserTarget(action)
		} catch {
			self.error = "The browser could not be opened. Try again."
		}
	}

	private func close() {
		guard !busy else { return }
		if confirmDisconnect {
			confirmDisconnect = false
			error = nil
			return
		}
		if status.pending || signingIn {
			control(close: true) { try await op("cancel") }
			return
		}
		dismiss()
	}

	private func op(_ name: String, _ fields: [String: JSONValue] = [:]) async throws {
		try await model.client.subscriptionControl(provider.providerId, op: name, fields: fields)
	}

	private func control(close: Bool = false, _ action: @escaping () async throws -> Void) {
		guard !busy else { return }
		controlling = true
		error = nil
		Task {
			do {
				try await action()
				await model.reloadSubscriptions()
				await model.reloadCatalog()
				controlling = false
				if close { dismiss() }
			} catch {
				controlling = false
				self.error = "The connection could not be changed. Try again."
			}
		}
	}
}

private struct SafariTarget: Identifiable {
	let url: URL
	var id: String { url.absoluteString }
}

/// The provider's sign-in page in an in-app Safari sheet (shares Safari's
/// sign-in cookies).
private struct SafariView: UIViewControllerRepresentable {
	let url: URL

	func makeUIViewController(context: Context) -> SFSafariViewController {
		SFSafariViewController(url: url)
	}

	func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
