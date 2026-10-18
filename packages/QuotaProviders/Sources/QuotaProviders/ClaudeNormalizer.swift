import Foundation
import QuotaCore

/// Official Claude Code status-line quota fields, not context-window occupancy.
/// The caller supplies the original event time and an explicitly authorized account handle.
public enum ClaudeNormalizer {
    private struct Input: Decodable { let rate_limits: Limits? }
    private struct Limits: Decodable { let five_hour: Window?; let seven_day: Window? }
    private struct Window: Decodable { let used_percentage: Decimal; let resets_at: Int64? }
    public static func normalize(_ data: Data, accountID: String, observedAt: Date) throws -> [QuotaWindow] {
        guard data.count <= 32_768 else { throw ProviderFailure.outputLimit }
        let input: Input
        do { input = try JSONDecoder().decode(Input.self, from: data) } catch { throw ProviderFailure.parseChanged }
        var result: [QuotaWindow] = []
        for (name, duration, window) in [("five-hour", 18000, input.rate_limits?.five_hour), ("seven-day", 604800, input.rate_limits?.seven_day)] {
            guard let window else { continue }
            let bps: Int
            do { bps = try QuotaRules.remainingBps(usedPercent: NSDecimalNumber(decimal: window.used_percentage).stringValue) }
            catch { throw ProviderFailure.parseChanged }
            result.append(.reported(id: "claude-" + name, providerID: "claude", accountID: accountID, alias: "Claude", key: name,
                remainingBps: bps, observedAt: observedAt, staleAt: observedAt.addingTimeInterval(600), duration: duration,
                resetsAt: window.resets_at.map { Date(timeIntervalSince1970: Double($0)) }, source: .localFile))
        }
        guard !result.isEmpty else { throw ProviderFailure.unsupported }
        return result
    }
}
