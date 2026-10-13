import RtechWhisperKit
import SwiftUI
import UIKit

/// Settings, as a sheet: the hub this phone talks to, the AI toggles, and
/// what build this is.
struct SettingsView: View {
    let connection: HubConnection
    @Bindable var ai: AISettingsStore
    @Bindable var app: AppSettingsStore
    @Environment(\.dismiss) private var dismiss

    private var hub: HubSettingsSummary {
        HubSettingsSummary(state: connection.state)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Hub") {
                    LabeledContent("Hub", value: hub.hubURL)
                    Text(hub.statusLine)
                    if hub.hasStoredKey {
                        Button("Forget this key", role: .destructive) {
                            connection.forget()
                            dismiss()
                        }
                    }
                }
                Section {
                    Toggle("AI cleanup", isOn: $ai.useCleanupModel)
                    Toggle("Remove filler words", isOn: $ai.removeFillerWords)
                    Toggle("Auto-generate titles", isOn: $ai.autoGenerateTitle)
                    Toggle("Read replies aloud", isOn: $ai.assistantSpeechEnabled)
                    LabeledContent("Model", value: ai.model)
                } header: {
                    Text("AI")
                } footer: {
                    Text("Cleanup tidies each dictation through the hub; titles are written for notes that have none. Read replies aloud speaks each chat reply in Skippy's voice.")
                }
                Section {
                    Toggle("Start and stop sounds", isOn: $app.audioCuesEnabled)
                    Toggle("Transcribe on this iPhone", isOn: $app.transcribeOnDevice)
                    Picker("Language", selection: $app.transcriptionLanguage) {
                        ForEach(TranscriptionLanguage.all) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.navigationLink)
                } header: {
                    Text("Dictation")
                } footer: {
                    Text("Uses Apple's on-device speech recognition. Falls back to the hub if on-device speech is unavailable. Language applies to both; Auto-detect lets the hub detect it and uses this iPhone's language on device.")
                }
                Section {
                    Picker("Keep on this iPhone", selection: $app.historyRetention) {
                        ForEach(HistoryRetention.allCases) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("History")
                } footer: {
                    Text("Older dictations are removed from this iPhone only. Your Mac keeps them all.")
                }
                Section {
                    Text("In Settings, open General > Keyboard > Keyboards > Add New Keyboard and add rTech Whisper. Then tap rTech Whisper there and turn on Allow Full Access.")
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        Link("Open Settings", destination: url)
                    }
                } header: {
                    Text("Keyboard")
                } footer: {
                    Text("The keyboard's Dictate key opens this app to record, and your text is typed into the field you came from. Full Access lets the keyboard open this app and receive the text; nothing you type is sent anywhere.")
                }
                Section("About") {
                    LabeledContent("Version", value: AppInfo.version(bundle: .main))
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
