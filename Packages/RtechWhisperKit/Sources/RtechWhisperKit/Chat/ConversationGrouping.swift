import Foundation

/// Conversations under one date heading, most recently active first.
public struct ConversationGroup: Sendable, Equatable, Identifiable {
    public let label: String
    public let conversations: [ChatConversation]

    public var id: String { label }

    public init(label: String, conversations: [ChatConversation]) {
        self.label = label
        self.conversations = conversations
    }
}

/// The desktop's `groupItemsByDate`: Today, Yesterday, Previous 7 Days,
/// Older, by the day of each conversation's last activity.
public enum ConversationGrouping {
    public static let today = "Today"
    public static let yesterday = "Yesterday"
    public static let previousWeek = "Previous 7 Days"
    public static let older = "Older"

    /// Groups `conversations` by `updatedAt`, newest first, in the calendar's
    /// days. Groups appear in date order and an empty group is left out.
    public static func group(
        _ conversations: [ChatConversation], now: Date = Date(), calendar: Calendar = .current
    ) -> [ConversationGroup] {
        let todayStart = calendar.startOfDay(for: now)
        guard let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart),
              let weekStart = calendar.date(byAdding: .day, value: -7, to: todayStart) else { return [] }
        var groups: [ConversationGroup] = []
        for conversation in conversations.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let day = calendar.startOfDay(for: conversation.updatedAt)
            let label = day >= todayStart ? today
                : day >= yesterdayStart ? yesterday
                : day >= weekStart ? previousWeek
                : older
            if let last = groups.indices.last, groups[last].label == label {
                groups[last] = ConversationGroup(label: label, conversations: groups[last].conversations + [conversation])
            } else {
                groups.append(ConversationGroup(label: label, conversations: [conversation]))
            }
        }
        return groups
    }
}
