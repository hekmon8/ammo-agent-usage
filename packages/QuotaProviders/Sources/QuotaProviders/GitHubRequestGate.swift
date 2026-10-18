import CryptoKit
import Foundation

/// A server deadline is anchored at response receipt, never at poll start.
struct GitHubRateLimitFailure: Error, Sendable {
    let retryNotBefore: Date

    func secondsRemaining(now: Date = Date()) -> Int {
        Int(min(Double(Int.max), max(1, ceil(retryNotBefore.timeIntervalSince(now)))))
    }

    static func deadline(status: Int, headers: [String: String], receivedAt: Date) -> Date? {
        guard status == 429 || (status == 403 &&
            (headers["x-ratelimit-remaining"] == "0" || headers["retry-after"] != nil)) else { return nil }
        var dates: [Date] = []
        if let value = headers["retry-after"] {
            if let seconds = Double(value), seconds.isFinite, seconds >= 0, seconds <= 315_360_000 {
                dates.append(receivedAt.addingTimeInterval(max(1, seconds)))
            } else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                if let date = formatter.date(from: value), date > receivedAt { dates.append(date) }
            }
        }
        if let raw = headers["x-ratelimit-reset"], let seconds = Double(raw), seconds.isFinite,
           seconds >= 0, seconds <= 253_402_300_799 {
            let date = Date(timeIntervalSince1970: seconds)
            if date > receivedAt { dates.append(date) }
        }
        return dates.max() ?? receivedAt.addingTimeInterval(60)
    }
}

/// Process-local and credential-specific. All live GitHub reads (identity,
/// expense and budgets) use this gate across probes, details and collectors.
/// Only a one-way credential digest is retained; no credential is persisted.
actor GitHubRequestGate {
    static let shared = GitHubRequestGate()
    static let cliKey = "gh-owned-login"
    private var deadlines: [String: Date] = [:]
    private var active: [String: (id: UUID, task: Task<Data, Error>)] = [:]

    static func key(forAuthorization value: String) -> String {
        "native-" + SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func deadline(key: String, now: Date = Date()) -> Date? {
        guard let date = deadlines[key], date > now else { deadlines[key] = nil; return nil }
        return date
    }

    func request(key: String, operation: @escaping @Sendable () async throws -> Data) async throws -> Data {
        if let previous = active[key] {
            _ = try? await previous.task.value
            try Task.checkCancellation()
            if active[key]?.id == previous.id { active[key] = nil }
            return try await request(key: key, operation: operation)
        }
        try Task.checkCancellation()
        if let date = deadline(key: key) { throw GitHubRateLimitFailure(retryNotBefore: date) }
        let id = UUID()
        let task = Task {
            do { return try await operation() }
            catch {
                // Record before resolving the task, so queued readers cannot
                // start between the response and its owner's continuation.
                if let date = GitHubBillingReader.retryDate(error, receivedAt: Date()) {
                    self.deadlines[key] = max(self.deadlines[key] ?? date, date)
                }
                throw error
            }
        }
        active[key] = (id, task)
        do {
            let data = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            if active[key]?.id == id { active[key] = nil }
            try Task.checkCancellation()
            return data
        } catch {
            if active[key]?.id == id { active[key] = nil }
            throw error
        }
    }
}
