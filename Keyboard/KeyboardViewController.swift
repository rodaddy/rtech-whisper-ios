import RtechWhisperKit
import SwiftUI
import UIKit

/// The rTech Whisper keyboard. A keyboard cannot use the microphone, so the
/// mic key opens the app, which records; the text comes back through the App
/// Group. The keyboard never inserts it on its own: it shows an Insert key,
/// and the person taps it in the field they want.
final class KeyboardViewController: UIInputViewController {
    private let statusLabel = UILabel()
    private let globeKey = UIButton(configuration: .gray())
    private let micKey = UIButton(configuration: .filled())
    private var micLink: UIHostingController<MicLink>?
    private let insertKey = UIButton(configuration: .tinted())
    private let discardKey = UIButton(configuration: .gray())
    private lazy var insertRow = UIStackView(arrangedSubviews: [insertKey, discardKey])
    private var timer: Timer?
    /// The take the Insert key shows; a tap inserts this take and no other.
    private var shownTake: UUID?

    override func viewDidLoad() {
        super.viewDidLoad()
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center

        globeKey.configuration?.image = UIImage(systemName: "globe")
        globeKey.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        globeKey.accessibilityLabel = "Next keyboard"

        micKey.configuration?.image = UIImage(systemName: "mic.fill")
        micKey.configuration?.title = "Dictate"
        micKey.configuration?.imagePadding = 6
        micKey.accessibilityLabel = "Dictate in rTech Whisper"
        let link = UIHostingController(rootView: MicLink(url: KeyboardRoute.dictate(hostBundle: nil).url))
        link.view.backgroundColor = .clear
        link.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(link)
        micKey.addSubview(link.view)
        link.didMove(toParent: self)
        NSLayoutConstraint.activate([
            link.view.leadingAnchor.constraint(equalTo: micKey.leadingAnchor),
            link.view.trailingAnchor.constraint(equalTo: micKey.trailingAnchor),
            link.view.topAnchor.constraint(equalTo: micKey.topAnchor),
            link.view.bottomAnchor.constraint(equalTo: micKey.bottomAnchor)
        ])
        micLink = link

        let space = key(title: "space", action: #selector(space))
        let delete = key(image: "delete.left", action: #selector(deleteBackward))
        delete.accessibilityLabel = "Delete"
        let ret = key(title: "return", action: #selector(newline))

        let keys = UIStackView(arrangedSubviews: [globeKey, delete, space, ret])
        keys.spacing = 6
        keys.distribution = .fill
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        [globeKey, delete, ret].forEach { $0.setContentHuggingPriority(.required, for: .horizontal) }

        insertKey.configuration?.titleLineBreakMode = .byTruncatingTail
        insertKey.addTarget(self, action: #selector(insert), for: .touchUpInside)
        discardKey.configuration?.image = UIImage(systemName: "xmark")
        discardKey.accessibilityLabel = "Discard dictation"
        discardKey.addTarget(self, action: #selector(discard), for: .touchUpInside)
        discardKey.setContentHuggingPriority(.required, for: .horizontal)
        insertKey.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        insertRow.spacing = 6
        insertRow.isHidden = true

        let column = UIStackView(arrangedSubviews: [statusLabel, insertRow, micKey, keys])
        column.axis = .vertical
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)
        // Below required: a hidden row collapses to zero in the stack.
        let insertHeight = insertRow.heightAnchor.constraint(equalToConstant: 44)
        insertHeight.priority = .init(999)
        // Tall enough for the Insert row; without it the column sits at the top.
        let height = view.heightAnchor.constraint(equalToConstant: 252)
        height.priority = .defaultHigh
        NSLayoutConstraint.activate([
            height,
            column.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            column.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            column.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            column.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -8),
            micKey.heightAnchor.constraint(equalToConstant: 72),
            keys.heightAnchor.constraint(equalToConstant: 44),
            insertHeight
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        micLink?.rootView = MicLink(url: KeyboardRoute.dictate(hostBundle: hostBundleID()).url)
        refresh()
        // The app may still be transcribing when the person comes back; the
        // poll only shows or hides the Insert key.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        timer?.invalidate()
        timer = nil
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        globeKey.isHidden = !needsInputModeSwitchKey
    }

    /// Show or hide the Insert key for waiting text, and what the app is
    /// doing. Nothing is inserted here: only a tap on Insert does that.
    private func refresh() {
        // Without Full Access the App Group is unreadable and no URL opens.
        guard hasFullAccess, let store = PendingTranscriptStore.shared() else {
            micKey.isEnabled = false
            micLink?.view.isUserInteractionEnabled = false
            showInsertKey(for: nil)
            statusLabel.text = "Allow Full Access in Settings to dictate."
            return
        }
        micKey.isEnabled = true
        micLink?.view.isUserInteractionEnabled = true
        let pending = store.pending
        showInsertKey(for: pending)
        statusLabel.text = switch store.status {
        case .recording: "Recording in rTech Whisper. Stop there, then come back."
        case .transcribing: "Transcribing in rTech Whisper…"
        case nil where pending != nil: "Tap Insert to type your dictation here."
        case nil: "Tap Dictate to talk."
        }
    }

    private func showInsertKey(for pending: PendingTranscript?) {
        shownTake = pending?.take
        insertRow.isHidden = pending == nil
        if let pending {
            insertKey.configuration?.title = KeyboardHandoff.insertTitle(for: pending.text)
        }
    }

    /// The person chose this field: insert the text the key showed, once.
    @objc private func insert() {
        guard let take = shownTake, let text = PendingTranscriptStore.shared()?.consume(take: take) else {
            refresh()
            return
        }
        textDocumentProxy.insertText(text)
        refresh()
    }

    @objc private func discard() {
        if let take = shownTake { PendingTranscriptStore.shared()?.discard(take: take) }
        refresh()
    }

    /// The app the keyboard is typing into, when iOS exposes it; the app
    /// uses it to send the person back there. Read through the host controller's
    /// `_hostBundleID`, as upstream OpenWhispr does, and only when that key
    /// exists, so a newer iOS without it cannot crash the keyboard.
    private func hostBundleID() -> String? {
        let key = "_hostBundleID"
        guard let parent, parent.responds(to: NSSelectorFromString(key)),
              let id = parent.value(forKey: key) as? String, !id.isEmpty, id != "<null>"
        else { return nil }
        return id
    }

    private func key(title: String? = nil, image: String? = nil, action: Selector) -> UIButton {
        let button = UIButton(configuration: .gray())
        button.configuration?.title = title
        button.configuration?.image = image.flatMap { UIImage(systemName: $0) }
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    @objc private func space() { textDocumentProxy.insertText(" ") }
    @objc private func deleteBackward() { textDocumentProxy.deleteBackward() }
    @objc private func newline() { textDocumentProxy.insertText("\n") }
}

/// The mic key's tap target. A keyboard extension has no `UIApplication` to
/// open a URL with; a SwiftUI `Link` inside the keyboard does open one when
/// Full Access is on (the route upstream OpenWhispr uses).
struct MicLink: View {
    let url: URL

    var body: some View {
        Link(destination: url) {
            Color.clear.contentShape(Rectangle())
        }
    }
}
