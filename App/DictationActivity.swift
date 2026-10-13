import ActivityKit
import Foundation
import RtechWhisperKit

/// Keeps the Live Activity in step with the dictation controller: a recording
/// starts it, transcribing updates it, and the result or error ends it after
/// a pause. The decisions are `DictationActivityStep.plan` in the kit; this
/// only talks to ActivityKit.
///
/// Every ActivityKit call runs on one `SerialTaskChain`, in the order the
/// states arrived when each finishes within the chain's `maxWait`: the launch
/// clean-up before any start, and a take's update before its end. A stalled
/// call can still land late, so `update` and `end` touch only the activity
/// their own take's request started, by the id it stored (#204). `Activity`
/// is not `Sendable`, so each call looks that activity up again inside the
/// task that awaits it.
@MainActor
final class DictationActivity {
    private let chain = SerialTaskChain()
    private let takes = DictationActivityTakes()
    private var startedAt = Date()

    /// Call on every `DictationController.state` change.
    func apply(state: DictationController.State, latestText: String?) {
        if state == .recording {
            startedAt = Date()
        }
        let content = DictationActivityContent(state: state, latestText: latestText, startedAt: startedAt)
        switch DictationActivityStep.plan(isActive: takes.isActive, content: content) {
        case .start(let content):
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            let take = takes.start()
            let state = DictationActivityAttributes.ContentState(content)
            let staleDate = content.staleDate(now: .now)
            chain.enqueue { [takes] in
                do {
                    take.activityID = try Activity.request(
                        attributes: DictationActivityAttributes(), content: .init(state: state, staleDate: staleDate)
                    ).id
                } catch {
                    // Nothing is showing, so the next recording starts afresh (#159).
                    await takes.requestFailed(take)
                }
            }
        case .update(let content):
            guard let take = takes.current else { return }
            let state = DictationActivityAttributes.ContentState(content)
            let staleDate = content.staleDate(now: .now)
            chain.enqueue {
                for activity in Self.active(of: take) {
                    await activity.update(.init(state: state, staleDate: staleDate))
                }
            }
        case .end(let content, let dismissAfter):
            guard let take = takes.end() else { return }
            let state = DictationActivityAttributes.ContentState(content)
            chain.enqueue {
                for activity in Self.active(of: take) {
                    await activity.end(.init(state: state, staleDate: nil), dismissalPolicy: .after(.now + dismissAfter))
                }
            }
        case .none:
            break
        }
    }

    /// Remove activities a killed process left behind; their recordings are
    /// gone, so there is nothing to show for them. Call at launch, before any
    /// take: the set is taken now, and the chain ends them before any start.
    func endLeftovers() {
        let leftovers = Set(Activity<DictationActivityAttributes>.activities.map(\.id))
        guard !leftovers.isEmpty else { return }
        chain.enqueue {
            for stale in Activity<DictationActivityAttributes>.activities where leftovers.contains(stale.id) {
                await stale.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// The activity `take`'s request started, while it still shows, stale
    /// included; an ended one waiting out its dismissal is left alone.
    private nonisolated static func active(of take: DictationActivityTakes.Take) -> [Activity<DictationActivityAttributes>] {
        guard let id = take.activityID else { return [] }
        return Activity<DictationActivityAttributes>.activities.filter {
            $0.id == id && ($0.activityState == .active || $0.activityState == .stale)
        }
    }
}

extension DictationActivityAttributes.ContentState {
    init(_ content: DictationActivityContent) {
        let phase: Phase = switch content.phase {
        case .recording: .recording
        case .transcribing: .transcribing
        case .done: .done
        case .failed: .failed
        }
        self.init(phase: phase, startedAt: content.startedAt, message: content.message)
    }
}
