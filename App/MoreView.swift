import RtechWhisperKit
import SwiftUI

/// The More tab: the desktop sidebar views that do not earn a tab of their
/// own on a phone, plus a way into Settings.
struct MoreView: View {
    /// The app's own dictionary, snippets, upload job, and notes: uploads save through
    /// the same stores the rest of the app uses and sync on the normal pass.
    let dictionary: DictionaryStore
    let snippets: SnippetStore
    let upload: UploadJob
    let notes: NotesViewModel
    @Binding var showsSettings: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(MoreFeature.allCases) { feature in
                        NavigationLink(value: feature) {
                            Label(feature.title, systemImage: feature.systemImage)
                        }
                    }
                }
                Section {
                    Button {
                        showsSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .navigationTitle("More")
            .navigationDestination(for: MoreFeature.self) { feature in
                switch feature {
                case .dictionary:
                    DictionaryView(store: dictionary)
                case .snippets:
                    SnippetsView(store: snippets)
                case .upload:
                    UploadView(upload: upload, notes: notes)
                }
            }
        }
    }
}
