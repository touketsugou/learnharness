import LHAPI
import SwiftUI

/// First launch (and after sign-out): the server address and access token.
struct ConnectionView: View {
	@Environment(AppModel.self) private var model
	@State private var address = ""
	@State private var token = ""
	@State private var connecting = false
	@State private var error: String?

	var body: some View {
		NavigationStack {
			Form {
				Section {
					TextField("learn.example.com", text: $address)
						.textContentType(.URL)
						.keyboardType(.URL)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
					SecureField("Access token", text: $token)
						.textContentType(.password)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
				} header: {
					Text("Server")
				} footer: {
					Text("The address of your LearnHarness cloud server and the LH_REMOTE_TOKEN it was started with. The token is stored in this device's Keychain.")
				}
				if let error {
					Section {
						Label(error, systemImage: "exclamationmark.triangle")
							.foregroundStyle(.red)
					}
				}
				Section {
					Button {
						Task { await connect() }
					} label: {
						HStack {
							Text("Connect")
							Spacer()
							if connecting { ProgressView() }
						}
					}
					.disabled(connecting || address.isEmpty || token.isEmpty)
				}
			}
			.navigationTitle("LearnHarness")
			.onAppear { if address.isEmpty { address = model.serverAddress ?? "" } }
		}
	}

	private func connect() async {
		connecting = true
		error = nil
		defer { connecting = false }
		do {
			try await model.connect(address: address, token: token)
		} catch let failure as APIError {
			error = switch failure {
			case .unauthorized: "The server rejected this access token."
			case .transport(let message): "Couldn't reach the server: \(message)"
			default: failure.message
			}
		} catch {
			self.error = error.localizedDescription
		}
	}
}
