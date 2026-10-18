import SwiftUI
import QuotaCore
import QuotaDesign

/// Local diagnostic/cost projection deliberately excluded from receipts and sync.
struct TokenUsageLocalAnalysisView: View {
    let analysis: TokenUsageLocalAnalysis
    let period: TokenUsagePeriod
    let anchor: Date
    let timeZone: TimeZone
    let stale: Bool
    private var cost: TokenUsageCostSummary? { analysis.summary(period: period, anchor: anchor, in: timeZone) }
    private let reasons = ["byte_budget", "oversized_lines", "ambiguous_fork_rows", "unowned_request_rows",
        "unreconciled_legacy_rows", "invalid_usage_rows", "malformed_rows", "counter_rewinds",
        "conflicting_request_rows", "event_limit", "file_limit", "enumeration_limit", "enumeration_failed",
        "root_unavailable", "read_failure", "future_usage_rows", "aggregate_overflow"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L("tokenUsage.cost.title")).font(.headline)
                Spacer()
                Text(cost?.standardUSD.map { String(format: "~$%.2f USD", $0) } ?? L("tokenUsage.cost.unknown"))
                    .font(.title2.bold()).monospacedDigit()
            }
            Text(L("tokenUsage.cost.basis")).font(.caption).foregroundStyle(.secondary)
            if let cost {
                Text(L("tokenUsage.cost.coverage", TokenUsageText.number(cost.pricedTokens), TokenUsageText.number(cost.unpricedTokens)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if stale { Label(L("tokenUsage.cost.historical"), systemImage: "clock").font(.caption).foregroundStyle(.secondary) }
            DisclosureGroup(L("tokenUsage.cost.method")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("tokenUsage.cost.localOnly"))
                    Text(L("tokenUsage.cost.priceDate", analysis.priceVersion))
                    HStack {
                        Link(L("tokenUsage.cost.openAIPrice"), destination: TokenUsagePricing.openAISource)
                        Link(L("tokenUsage.cost.claudePrice"), destination: TokenUsagePricing.claudeSource)
                    }

                    Text(L("tokenUsage.cost.formula"))
                    Text(L("tokenUsage.cost.unknownExplanation"))
                    Text(L("tokenUsage.cost.contextExplanation"))
                    Text(L("tokenUsage.cost.modeExplanation"))
                    ForEach(["gpt-6-astra", "gpt-6.1-sol", "gpt-6-luna", "gpt-6-sol", "gpt-5.6-sol", "gpt-5.6-terra"], id: \.self) { model in
                        if let rate = TokenUsagePricing.rate(agent: .codex, model: model) {
                            Text(L("tokenUsage.cost.modelRates", model,
                                String(format: "%g / %g / %g / %g", rate.input, rate.cacheRead, rate.cacheWrite, rate.output)))
                        }
                    }
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }
            DisclosureGroup(L("tokenUsage.scan.scope")) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(analysis.sources, id: \.agent) { source in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(TokenUsageText.agent(source.agent)).font(.subheadline.bold())
                            Text(L("tokenUsage.scan.files", source.readFiles, source.discoveredFiles,
                                String(format: "%.2f", Double(source.bytesRead) / 1_073_741_824),
                                String(format: "%.2f", Double(source.byteLimit) / 1_073_741_824)))
                            if source.reusedUnchangedFiles { Text(L("tokenUsage.scan.reused")) }
                            ForEach(reasons.filter { (source.reasons[$0] ?? 0) > 0 }, id: \.self) { reason in
                                Text(reasonLabel(reason) + " · " + String(source.reasons[reason]!))
                            }
                        }
                    }
                    Text(L("tokenUsage.scan.limits"))
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }
        }.padding(18).studioSurface(radius: 14)
    }

    private func reasonLabel(_ reason: String) -> String {
        switch reason {
        case "byte_budget": return L("tokenUsage.scan.reason.byte_budget")
        case "oversized_lines": return L("tokenUsage.scan.reason.oversized_lines")
        case "ambiguous_fork_rows": return L("tokenUsage.scan.reason.ambiguous_fork_rows")
        case "unowned_request_rows": return L("tokenUsage.scan.reason.unowned_request_rows")
        case "unreconciled_legacy_rows": return L("tokenUsage.scan.reason.unreconciled_legacy_rows")
        case "invalid_usage_rows": return L("tokenUsage.scan.reason.invalid_usage_rows")
        case "malformed_rows": return L("tokenUsage.scan.reason.malformed_rows")
        case "counter_rewinds": return L("tokenUsage.scan.reason.counter_rewinds")
        case "conflicting_request_rows": return L("tokenUsage.scan.reason.conflicting_request_rows")
        case "event_limit": return L("tokenUsage.scan.reason.event_limit")
        case "file_limit": return L("tokenUsage.scan.reason.file_limit")
        case "enumeration_limit": return L("tokenUsage.scan.reason.enumeration_limit")
        case "enumeration_failed": return L("tokenUsage.scan.reason.enumeration_failed")
        case "root_unavailable": return L("tokenUsage.scan.reason.root_unavailable")
        case "read_failure": return L("tokenUsage.scan.reason.read_failure")
        case "future_usage_rows": return L("tokenUsage.scan.reason.future_usage_rows")
        case "aggregate_overflow": return L("tokenUsage.scan.reason.aggregate_overflow")
        default: return ""
        }
    }
}
