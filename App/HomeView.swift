import RtechWhisperKit
import SwiftUI

/// The Home tab: dictate, read and copy the text, and scroll the transcription
/// history. Before a key is stored it shows onboarding instead.
struct HomeView: View {
    let connection: HubConnection
    let dictation: DictationController
    let notes: NotesViewModel
    let history: HistoryViewModel
    @State private var selected: TranscriptionRecord?

    var body: some View {
        switch connection.state {
        case .needsKey:
            OnboardingView(connection: connection)
        case .checking:
            ProgressView("Checking the hub…")
        case .connected:
            connected(message: nil)
        case .stored(let error):
            connected(message: "Key stored, but the hub check failed: \(error.userMessage)")
        }
    }

    private func connected(message: String?) -> some View {
        List {
            Section {
                VStack(spacing: 16) {
                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Try again") {
                            Task { await connection.restore() }
                        }
                    }
                    DictateView(dictation: dictation, notes: notes, history: history)
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                .listRowBackground(Color.clear)
            }
            Section("History") {
                HistoryRows(history: history, selected: $selected)
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await history.refresh() }
        .task { await history.load() }
        .sheet(item: $selected) { item in
            HistoryDetailView(item: item, notes: notes)
        }
    }
}

extension TranscriptionRecord: @retroactive Identifiable {
    public var id: String { clientId }
}
