import AudioToolbox
import Foundation
import RtechWhisperKit
import SwiftUI
import UIKit

@main
struct RtechWhisperApp: App {
    /// Hands a background relaunch's upload events to the uploader.
    @UIApplicationDelegateAdaptor(UploadAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    /// Set when the scene goes to the background, so a kept upload is retried
    /// on a return from it, not on every inactive-to-active (Control Centre, alerts).
    @State private var returnsFromBackground = false
    @State private var connection = HubConnection(
        client: HubClient(),
        store: KeychainDeviceKeyStore()
    )
    @State private var dictation: DictationController
    @State private var notes: NotesViewModel
    @State private var history: HistoryViewModel
    @State private var aiSettings = AISettingsStore()
    @State private var appSettings = AppSettingsStore()
    @State private var titler: NoteAutoTitler
    /// The note editor's AI actions, run through the same LLM relay.
    @State private var noteActions: NoteActionRunner
    /// One dictionary for the whole app: the Dictionary screen edits it, and
    /// dictation and uploads both send its hint as the relay's `prompt`.
    @State private var dictionary: DictionaryStore
    /// Spoken triggers that dictation expands to saved text; synced like the dictionary.
    @State private var snippets: SnippetStore
    @State private var upload: UploadJob
    /// The chat with the agent: one session over the app's notes, its saved
    /// conversations, and the composer's mic.
    @State private var chat: ChatSession
    @State private var chats: ChatConversationsViewModel
    @State private var voiceDraft: VoiceDraft
    /// The Brain dump tab's mic: its own take, never the dictation queue.
    @State private var dumpDraft: VoiceDraft
    /// Reads chat replies aloud in the hub's voice through the hub.
    @State private var speaker: ReplySpeaker
    /// Start-dictation requests from Siri, Shortcuts, the Action button, and
    /// the Control Center control.
    private let launch: DictationLaunch
    /// Brain dump requests from the same places.
    private let dumpLaunch = BrainDumpLaunch()
    /// The Dynamic Island and Lock Screen view of the take in progress: the
    /// phone's version of the desktop floating pill.
    private let activity = DictationActivity()
    /// A take the keyboard asked for: its text goes back through the App Group.
    @State private var keyboard = KeyboardDictation(store: PendingTranscriptStore.shared())

    init() {
        let dictionary = DictionaryStore(persistence: UserDefaultsDictionaryPersistence())
        _dictionary = State(initialValue: dictionary)
        let snippets = SnippetStore(persistence: UserDefaultsSnippetPersistence())
        _snippets = State(initialValue: snippets)
        let (notes, history) = Self.makeNotesAndHistory(dictionary: dictionary, snippets: snippets)
        _notes = State(initialValue: notes)
        _history = State(initialValue: history)
        let aiSettings = AISettingsStore()
        _aiSettings = State(initialValue: aiSettings)
        let appSettings = AppSettingsStore()
        _appSettings = State(initialValue: appSettings)
        history.retention = { appSettings.historyRetention }
        // Cleanup, titles, and the chat go through the hub's LLM relay with the
        // stored device key, read per call; the toggles are read per call too.
        let llm = KeyedLLMClient(keys: KeychainDeviceKeyStore(), configuration: HubConfiguration())
        let titler = NoteAutoTitler(
            notes: notes,
            generate: { content in await TitleService(llm: llm).generate(content) },
            isEnabled: { aiSettings.autoGenerateTitle })
        _titler = State(initialValue: titler)
        notes.onCreated = { _ = titler.noteClosed($0.clientId) }
        _noteActions = State(initialValue: NoteActionRunner(notes: notes, llm: llm))
        let dictation = Self.makeDictation(dictionary: dictionary, snippets: snippets, appSettings: appSettings)
        // Cleanup keeps the snippet triggers as spelled, then the triggers
        // expand, as on the desktop.
        dictation.postProcessor = DictationPostProcessor(
            llm: llm, settings: { await aiSettings.cleanupSettings(dictionary: dictionary.words + snippets.triggers) },
            expand: { await snippets.expand($0) })
        // Every finished dictation lands in the history as transcribed, as on
        // the desktop: the cleaned text as `text`, Whisper's words as
        // `rawText`; edits in the field never change it. Wired here, not in
        // the view's task, so an intent that runs before any view still has it.
        // The row is saved before the controller marks the item reported, so
        // a failed save is retried on the next pass instead of lost. The row
        // is keyed by the queue id, so Delete on the card finds it.
        dictation.onTranscribed = { [history] item in
            guard let raw = item.whisperText else { return }
            let saved = await history.record(
                text: item.cleanedText ?? raw, rawText: raw, provider: HistoryFormatting.provider(for: item.source),
                durationMs: item.durationMs, clientId: item.id.uuidString)
            guard saved != nil else { throw HistorySaveFailed() }
        }
        _dictation = State(initialValue: dictation)
        let upload = Self.makeUpload(dictionary: dictionary, history: history, appSettings: appSettings)
        _upload = State(initialValue: upload)
        // A background relaunch may connect no scene, so the kept upload is
        // carried on from there too: its answer is taken, the next chunk sent.
        UploadAppDelegate.carryOnUploads = { await upload.carryOnAfterEvents() }
        let (chat, chats) = Self.makeChat(notes: notes, llm: llm)
        _chat = State(initialValue: chat)
        _chats = State(initialValue: chats)
        let voiceDraft = Self.makeVoiceDraft(dictionary: dictionary, dictation: dictation, appSettings: appSettings)
        _voiceDraft = State(initialValue: voiceDraft)
        let dumpDraft = Self.makeDumpDraft(dictionary: dictionary, appSettings: appSettings, otherCaptureActive: {
            dictation.state == .recording || voiceDraft.status == .recording })
        _dumpDraft = State(initialValue: dumpDraft)
        _speaker = State(initialValue: ReplySpeaker(
            synthesize: Self.speech(), player: AudioReplyPlayer(),
            otherCaptureActive: {
                dictation.state == .recording || voiceDraft.status == .recording || dumpDraft.status == .recording },
            isEnabled: { aiSettings.assistantSpeechEnabled }))
        let launch = DictationLaunch()
        self.launch = launch
        StartDictationIntent.onPerform = { launch.request() }
        BrainDumpIntent.onPerform = { [dumpLaunch] in dumpLaunch.request() }
        // The Live Activity's Stop button ends the take without opening the
        // app; set at launch so Stop works even before a view appears.
        StopDictationIntent.onPerform = { [dictation] in await dictation.stop() }
        // Activities a killed process left behind have no take behind them.
        activity.endLeftovers()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                connection: connection, dictation: dictation, notes: notes, history: history,
                aiSettings: aiSettings, appSettings: appSettings, titler: titler, dictionary: dictionary, snippets: snippets,
                upload: upload, launch: launch, dumpLaunch: dumpLaunch, keyboard: keyboard,
                chat: chat, chats: chats, voiceDraft: voiceDraft, dumpDraft: dumpDraft)
                .environment(noteActions)
                .environment(speaker)
                .task { await dictation.start() }
                // The history is trimmed on this iPhone first, then
                // one pass syncs notes, pushes transcriptions, syncs the
                // dictionary and snippets, and refreshes the history list.
                .task {
                    await history.applyRetention(appSettings.historyRetention)
                    await history.refresh()
                }
                // An upload the last process did not finish carries on from its saved chunks.
                .task { await UploadView.inBackgroundTask { await upload.resumeUnfinished() } }
                .onChange(of: dictation.state) { old, state in
                    activity.apply(state: state, latestText: dictation.latestText)
                    // The system record begin/end sounds, as the desktop's start/stop cues.
                    if appSettings.audioCuesEnabled, let cue = DictationCue.forChange(from: old, to: state) {
                        AudioServicesPlaySystemSound(cue == .start ? 1113 : 1114)
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await dictation.retry() }
                Task { await history.refresh() }
                // A kept upload, a truncated one included, is retried on a return from the background too.
                if returnsFromBackground {
                    returnsFromBackground = false
                    Task { await UploadView.inBackgroundTask { await upload.resumeUnfinished() } }
                }
            } else if phase == .background {
                returnsFromBackground = true
                // A composer take has no Live Activity and no Stop outside
                // the app; it ends when the app leaves the screen. Not on
                // .inactive: the permission prompt makes the scene inactive.
                // The Brain dump take is not cancelled here: ContentView
                // stops it and keeps its text in the box.
                voiceDraft.cancel()
            }
        }
    }

    /// Notes and the transcription history live in on-disk SwiftData stores
    /// and sync through the hub with the stored device key, in one pass: the
    /// engine runs the notes step, then the transcription step, then the
    /// dictionary and snippet steps, and the history refreshes by asking the
    /// notes to sync. With no key, sync stays off.
    private static func makeNotesAndHistory(
        dictionary: DictionaryStore, snippets: SnippetStore
    ) -> (NotesViewModel, HistoryViewModel) {
        let noteStore: NotesStore
        do {
            noteStore = try NotesStore.persistent()
        } catch {
            // The app still opens; notes this session are not kept.
            noteStore = try! NotesStore.inMemory()
        }
        let transcriptionStore: TranscriptionStore
        do {
            transcriptionStore = try TranscriptionStore.persistent()
        } catch {
            transcriptionStore = try! TranscriptionStore.inMemory()
        }
        let hub = KeyedHubSync(keys: KeychainDeviceKeyStore(), configuration: HubConfiguration())
        let cursors = UserDefaultsCursorStore()
        let transcriptions = TranscriptionSync(hub: hub, store: transcriptionStore)
        let dictionarySync = DictionarySync(hub: hub, store: dictionary, cursors: cursors)
        let snippetSync = SnippetSync(hub: hub, store: snippets, cursors: cursors)
        let engine = SyncEngine(
            hub: hub, store: noteStore, cursors: cursors, transcriptions: transcriptions, dictionary: dictionarySync,
            snippets: snippetSync)
        let notes = NotesViewModel(store: noteStore, engine: engine, canSync: { hub.hasKey })
        let history = HistoryViewModel(store: transcriptionStore, sync: { [notes] in await notes.syncNow() })
        return (notes, history)
    }

    /// One send to the relay. Each send reads the key from the Keychain, so a
    /// key pasted later is picked up without a restart, and the language
    /// setting, so a new choice applies to the next send.
    private static func relay(_ appSettings: AppSettingsStore) -> TranscribeWithPrompt {
        let store = KeychainDeviceKeyStore()
        return { wav, prompt throws(HubError) in
            guard let key = try? store.load() else { throw .unauthorized }
            let language = await appSettings.transcriptionLanguage.hubLanguage
            return try await TranscriptionClient(key: key).transcribe(wav: wav, language: language, prompt: prompt)
        }
    }

    /// Apple speech in the chosen language; the phone's own locale for Auto.
    private static func onDeviceSpeech(_ appSettings: AppSettingsStore) -> AppleOnDeviceSpeech {
        AppleOnDeviceSpeech(currentLocale: { appSettings.transcriptionLanguage.locale ?? .current })
    }

    /// One reply to the speech relay, with the key read per call like `relay()`.
    private static func speech() -> ReplySpeaker.Synthesize {
        let store = KeychainDeviceKeyStore()
        return { text throws(HubError) in
            guard let key = try? store.load() else { throw .unauthorized }
            return try await SpeechRelay.synthesize(text, key: key)
        }
    }

    /// The queue lives in Application Support; every send carries the
    /// dictionary words and snippet triggers as the relay's `prompt`, as the
    /// desktop's `getDictionaryHintWords` does, so a trigger is heard as spelled.
    private static func makeDictation(dictionary: DictionaryStore, snippets: SnippetStore, appSettings: AppSettingsStore) -> DictationController {
        let directory = URL.applicationSupportDirectory.appending(path: "Dictations", directoryHint: .isDirectory)
        return DictationController(
            recorder: EngineRecorder(),
            queue: DictationQueue(directory: directory),
            transcribe: prompted(relay(appSettings), hint: { DictionaryStore.promptHint(dictionary.words + snippets.triggers) }),
            onDevice: onDeviceSpeech(appSettings),
            requestMicrophone: MicrophonePermission.request,
            reachability: PathReachability(),
            transcribeOnDevice: { appSettings.transcribeOnDevice }
        )
    }

    /// The chat talks to the hub's LLM relay with the stored device key, read
    /// per request like the rest of the app, runs the desktop's note tools
    /// over the app's notes, and keeps its conversations in a store of its
    /// own on this phone.
    private static func makeChat(notes: NotesViewModel, llm: KeyedLLMClient) -> (ChatSession, ChatConversationsViewModel) {
        let store: ChatStore
        do {
            store = try ChatStore.persistent()
        } catch {
            // The app still opens; chats this session are not kept.
            store = try! ChatStore.inMemory()
        }
        let session = ChatSession(llm: llm, tools: NoteTools.all(notes: notes), store: store)
        return (session, ChatConversationsViewModel(store: store))
    }

    /// The composer's mic: a take goes through the same relay with the
    /// dictionary hint, and on-device speech answers when the hub cannot.
    /// One microphone owner at a time: no take while a dictation records.
    private static func makeVoiceDraft(dictionary: DictionaryStore, dictation: DictationController, appSettings: AppSettingsStore) -> VoiceDraft {
        VoiceDraft(
            recorder: EngineRecorder(),
            transcribe: prompted(relay(appSettings), hint: { dictionary.promptHint() }),
            onDevice: onDeviceSpeech(appSettings),
            requestMicrophone: MicrophonePermission.request,
            otherCaptureActive: { [dictation] in dictation.state == .recording }
        )
    }

    /// The Brain dump mic: the same relay and on-device seam as dictation,
    /// honouring Transcribe on this iPhone. The text goes back to the box only.
    private static func makeDumpDraft(
        dictionary: DictionaryStore, appSettings: AppSettingsStore, otherCaptureActive: @escaping @MainActor () -> Bool
    ) -> VoiceDraft {
        VoiceDraft(
            recorder: EngineRecorder(),
            transcribe: prompted(relay(appSettings), hint: { dictionary.promptHint() }),
            onDevice: onDeviceSpeech(appSettings),
            requestMicrophone: MicrophonePermission.request,
            otherCaptureActive: otherCaptureActive,
            transcribeOnDevice: { appSettings.transcribeOnDevice })
    }

    /// Uploads send through the same relay with the dictionary hint, and every
    /// finished upload lands in the app's history as transcribed, as a
    /// dictation does, so it syncs on the normal pass. Each upload is saved
    /// as it goes, so a relaunch resumes it; without the store it is not kept.
    private static func makeUpload(dictionary: DictionaryStore, history: HistoryViewModel, appSettings: AppSettingsStore) -> UploadJob {
        let upload = UploadJob(
            decode: { url in try AudioFileDecoder.open(url) },
            transcribe: relay(appSettings),
            prompt: { dictionary.promptHint() },
            saving: try? UploadSaving.persistent(),
            background: backgroundUploader(appSettings)
        )
        // Awaited, so the kept upload is deleted only once its row is saved;
        // a failed save keeps it for the next launch, and its clientId stops
        // a finish replayed after a kill from adding a second row.
        upload.onTranscribed = { [history] result in
            let saved = await history.record(
                text: result.text, rawText: result.text, provider: HistoryFormatting.hubProvider,
                durationMs: result.durationMs, clientId: result.clientId)
            guard saved != nil else { throw HistorySaveFailed() }
        }
        return upload
    }
}

/// The one background upload session, made once so a relaunch's
/// events and the Upload screen share it. Bodies wait in Application Support.
@MainActor private var sharedUploader: BackgroundUploader?

@MainActor func backgroundUploader(_ appSettings: AppSettingsStore? = nil) -> BackgroundUploader {
    if let sharedUploader { return sharedUploader }
    let store = KeychainDeviceKeyStore()
    let uploader = BackgroundUploader(
        directory: URL.applicationSupportDirectory.appending(path: "UploadBodies", directoryHint: .isDirectory)
    ) { () throws(HubError) in
        guard let key = try? store.load() else { throw .unauthorized }
        let language = await appSettings?.transcriptionLanguage.hubLanguage
        return (TranscriptionClient(key: key), language)
    }
    sharedUploader = uploader
    return uploader
}

/// Keeps the system's completion handler for a background relaunch until
/// the kept upload's next chunk is handed to the system, or no chunk is left
/// to send, under a background task begun as soon as the session's events
/// are in. Calling the handler earlier lets iOS suspend the app before the
/// next chunk is sent, and nothing would wake it again.
final class UploadAppDelegate: NSObject, UIApplicationDelegate {
    /// Carries on the kept upload, returning once its next chunk is on its
    /// way or none is left (`UploadJob.carryOnAfterEvents`); set by the app at launch.
    @MainActor static var carryOnUploads: (() async -> Void)?

    func application(
        _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundUploader.identifier else { return completionHandler() }
        nonisolated(unsafe) let handler = completionHandler
        backgroundUploader().setEventsFinished {
            // Called on the main queue, after every answer is on disk.
            MainActor.assumeIsolated {
                let hold = EventsHold(handler)
                Task {
                    await Self.carryOnUploads?()
                    hold.release()
                }
            }
        }
    }
}

/// The system's completion handler for a background session's events, held
/// under a background task until `release`, or until the task expires. Both
/// the handler and the task end exactly once.
@MainActor private final class EventsHold {
    private var handler: (() -> Void)?
    private var task = UIBackgroundTaskIdentifier.invalid

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
        task = UIApplication.shared.beginBackgroundTask(withName: "Upload events") { [self] in
            MainActor.assumeIsolated { release() }
        }
    }

    func release() {
        handler?()
        handler = nil
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}

/// A dictation's or upload's history row was not saved; `HistoryViewModel` already shows
/// why. Thrown so the item is kept and retried instead of marked done.
private struct HistorySaveFailed: Error {}
