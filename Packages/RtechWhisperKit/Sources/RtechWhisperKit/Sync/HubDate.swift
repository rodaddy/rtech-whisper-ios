import Foundation

/// The hub's one timestamp format: ISO 8601 UTC with milliseconds and `Z`,
/// e.g. `2026-09-29T10:15:30.123Z` (protocol section 1).
///
/// Formatting is done by hand around whole seconds, so a millisecond value
/// survives decode and encode exactly instead of drifting through a
/// floating-point fraction.
public enum HubDate {
    private static let wholeSeconds = Date.ISO8601FormatStyle()

    /// Formats `date` as `yyyy-MM-ddTHH:mm:ss.SSSZ`, truncated to the
    /// millisecond. A delta `since` must never round up past the clock it was
    /// taken from, or a row stamped in that half millisecond is skipped
    /// (protocol section 8). The value is first rounded to the microsecond so
    /// an exact millisecond held in a `Double` (for example 122.9999999 ms)
    /// is not truncated down a whole millisecond.
    public static func string(from date: Date) -> String {
        let totalUs = Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
        let totalMs = totalUs >= 0 ? totalUs / 1000 : (totalUs - 999) / 1000
        let seconds = totalMs >= 0 ? totalMs / 1000 : (totalMs - 999) / 1000
        let millis = totalMs - seconds * 1000
        let base = wholeSeconds.format(Date(timeIntervalSince1970: TimeInterval(seconds)))
        return String(base.dropLast()) + String(format: ".%03lld", millis) + "Z"
    }

    /// Parses an ISO 8601 UTC timestamp ending in `Z`, with or without a
    /// fractional second. Digits past the millisecond are dropped.
    public static func date(from string: String) -> Date? {
        guard string.hasSuffix("Z") else { return nil }
        let body = string.dropLast()
        let parts = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let base = try? wholeSeconds.parse(String(parts[0]) + "Z") else { return nil }
        guard parts.count == 2 else { return base }
        let fraction = parts[1]
        guard (1...9).contains(fraction.count), fraction.allSatisfy(\.isASCIIDigit) else { return nil }
        let millis = Int(fraction.prefix(3).padding(toLength: 3, withPad: "0", startingAt: 0))!
        return Date(timeIntervalSince1970: base.timeIntervalSince1970 + Double(millis) / 1000)
    }

    /// A decoder that reads hub timestamps into `Date`. Keys are mapped by each
    /// type's own `CodingKeys`, not by a global key strategy.
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = date(from: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Not a hub timestamp: \(raw)")
            }
            return date
        }
        return decoder
    }

    /// An encoder that writes `Date` back in the hub's exact timestamp format.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
