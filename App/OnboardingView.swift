import RtechWhisperKit
import SwiftUI

/// Shown when no device key is stored: paste a key, check it with the hub.
struct OnboardingView: View {
    let connection: HubConnection
    @State private var pastedKey = ""

    var body: some View {
        Form {
            Section {
                SecureField("rtw_…", text: $pastedKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
            } header: {
                Text("Device key")
            } footer: {
                Text("Paste the key the hub minted for this iPhone.")
            }
            if let failure = connection.lastError {
                Section {
                    Text(failure.userMessage)
                        .foregroundStyle(.red)
                }
            }
            Section {
                Button("Connect") {
                    Task { await connection.connect(pastedKey: pastedKey) }
                }
                .disabled(DeviceKey.normalized(pastedKey).isEmpty)
            }
        }
    }
}

private extension HubConnection.ConnectFailure {
    var userMessage: String {
        switch self {
        case .hub(let error):
            error.userMessage
        case .keyNotSaved:
            "The hub accepted the key, but this iPhone could not save it."
        }
    }
}
