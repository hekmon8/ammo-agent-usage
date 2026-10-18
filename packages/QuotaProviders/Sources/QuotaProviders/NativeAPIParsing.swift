import Foundation

/// Small parsing helpers shared by the native API clients.
enum NativeAPIParsing {
    static func clampPercent(_ value: Double) -> Double {
        min(100, max(0, value))
    }

    /// "1,234.5" / "$99" → Double; refuses anything with signs or exponents.
    static func money(_ raw: String?) -> Double? {
        guard var raw else { return nil }
        raw = raw.replacingOccurrences(of: ",", with: "")
        guard raw.range(of: "^[0-9]+(\\.[0-9]+)?$", options: .regularExpression) != nil, let value = Double(raw) else { return nil }
        return value
    }

    /// ISO8601 with optional fractional seconds, falling back to a plain UTC date.
    static func date(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let date = ISO8601DateFormatter().date(from: raw) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw)
    }

    /// The free tier's advertised "resets daily" lands on 20:00 Eastern.
    static func nextEasternTwentyOClock(from now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        guard let eastern = TimeZone(identifier: "America/New_York") else { return now }
        calendar.timeZone = eastern
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = 20
        if let today = calendar.date(from: components), today > now { return today }
        components.day = (components.day ?? 1) + 1
        return calendar.date(from: components) ?? now
    }

    static func monthsFromNow(_ count: Int, from date: Date) -> Date {
        Calendar(identifier: .gregorian).date(byAdding: .month, value: count, to: date) ?? date
    }

    /// One-way credential-owner digest. The formula is load-bearing: it pins
    /// migrated connections' stored identity fingerprints, so it must not
    /// change (the inputs are the provider id and the exact credential text).
    static func legacyCredentialSeed(provider: String, material: String) -> String {
        NativeProviderNormalizer.sha256("credential\n\(provider)\n\(material)")
    }

    /// Multi-field variant; fields are sorted by key and joined as `key=value`.
    static func legacyCredentialsSeed(provider: String, values: [String: String]) -> String {
        let material = values.keys.sorted().compactMap { key in
            values[key].map { "\(key)=\($0)" }
        }.joined(separator: "\n")
        return legacyCredentialSeed(provider: provider, material: material)
    }
}

/// Errors raised by the native API clients after a successful transport.
enum NativeProviderAPIError: Error, Sendable {
    case authenticationRequired
    case credentialRejected
    case permissionDenied
    case rateLimited(seconds: Int?)
    case unavailable
    case parseFailure
}

/// Epoch seconds, epoch milliseconds, numeric strings, or ISO8601 — the date
/// shapes providers actually return for window ends.
struct NativeFlexibleDate: Decodable {
    let value: Date?

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let seconds = try? container.decode(Double.self) {
            value = Self.date(fromEpochLike: seconds)
        } else if let text = try? container.decode(String.self) {
            if let number = Double(text) {
                value = Self.date(fromEpochLike: number)
            } else {
                value = NativeAPIParsing.date(text)
            }
        } else {
            value = nil
        }
    }

    init?(epochLike number: Double) {
        guard let date = Self.date(fromEpochLike: number) else { return nil }
        value = date
    }

    static func date(fromEpochLike number: Double) -> Date? {
        if number > 1_000_000_000_000 { return Date(timeIntervalSince1970: number / 1000) }
        if number > 1_000_000_000 { return Date(timeIntervalSince1970: number) }
        return nil
    }
}
