import SwiftUI
import QuotaCore

/// Status precedence for compact rows, shared across Mac and iPhone.
public enum CompactMetricTone: Equatable {
    case muted, normal, warning, critical
    public init(_ value: QuotaPresentation, severity: BillingSeverity = .normal) {
        switch QuotaVisualState(value) {
        case .historical, .unavailable: self = .muted; return
        case .exhausted: self = .critical; return
        default: break
        }
        if severity == .critical { self = .critical }
        else if severity == .warning { self = .warning }
        else if let bps = value.visibleBps, !value.window.isConsumptionMetric {
            self = bps < 2000 ? .critical : bps <= 5000 ? .warning : .normal
        } else { self = .normal }
    }
}

/// Compact shared reading. Only bounded quota ratios receive a progress track;
/// historical and unavailable readings retain their visible status.
public struct BillingMetricRow: View {
    let value: QuotaPresentation
    let severity: BillingSeverity
    let rule: BillingRule?
    let showsAccount: Bool
    let compact: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var hovered = false
    public init(value: QuotaPresentation, severity: BillingSeverity = .normal, rule: BillingRule? = nil,
                showsAccount: Bool = true, compact: Bool = false) {
        self.value = value; self.severity = severity; self.rule = rule
        self.showsAccount = showsAccount; self.compact = compact
    }
    private var hasStatus: Bool {
        value.isHistorical || ![.fresh, .unlimited].contains(value.state) || value.window.quality != .reported
    }
    private var tone: Color {
        switch CompactMetricTone(value, severity: severity) {
        case .muted: PaperInk(scheme).muted
        case .normal: PaperInk(scheme).accent
        case .warning: amber
        case .critical: PaperInk(scheme).warning
        }
    }
    private var amber: Color {
        scheme == .dark ? Color(red: 0.91, green: 0.76, blue: 0.48) : Color(red: 0.53, green: 0.35, blue: 0.10)
    }
    public var body: some View {
        #if os(macOS)
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        identity.frame(maxWidth: .infinity, alignment: .leading)
                        reading.fixedSize(horizontal: true, vertical: false)
                    }
                    HStack(spacing: 12) {
                        progress.frame(width: 80)
                        metadata.frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            } else {
                HStack(spacing: 12) {
                    identity.frame(maxWidth: .infinity, alignment: .leading)
                    reading.frame(width: 90, alignment: .trailing)
                    progress.frame(width: 80)
                    metadata.frame(width: 112, alignment: .trailing)
                }
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(minHeight: 40)
        .background(hovered ? PaperInk(scheme).elevated : .clear)
        .contentShape(Rectangle()).onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
        #else
        VStack(alignment: .leading, spacing: 7) {
            if typeSize.isAccessibilitySize {
                identity
                reading
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    identity
                    Spacer(minLength: 4)
                    reading
                }
            }
            if typeSize.isAccessibilitySize {
                progress.frame(width: 96)
                metadata.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 12) {
                    progress.frame(maxWidth: 96)
                    Spacer(minLength: 0)
                    metadata
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(minHeight: 56).contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        #endif
    }
    private var identity: some View {
        HStack(spacing: 8) {
            if showsAccount { ProviderMark(providerID: value.window.providerId, size: 22) }
            VStack(alignment: .leading, spacing: 2) {
                Text(value.window.shortDisplayName).fontWeight(.medium)
                    .lineLimit(compact ? 2 : 1)
                    .truncationMode(.tail)
                if showsAccount {
                    Text(value.window.accountAlias).font(.caption).foregroundStyle(.secondary)
                }
                if value.window.providerId == "github-actions" {
                    if let month = GitHubActionsReporting.queryMonth(value.window) {
                        Text(L("billing.github.monthUTC", month)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(L("billing.github.cardUnknown")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
    private var reading: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value.number).fontWeight(.semibold).monospacedDigit()
                .foregroundStyle(value.isHistorical ? PaperInk(scheme).muted : tone)
                .fixedSize(horizontal: false, vertical: true)
            if let rule, rule.kind == .budget, rule.enabled, rule.isValid {
                Text(L("billing.rowBudget", rule.critical, rule.currency ?? ""))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(value.valueHeading + " " + value.number)
    }
    @ViewBuilder private var progress: some View {
        if let bps = value.visibleBps, !value.window.isConsumptionMetric {
            GeometryReader { geometry in
                Capsule().fill(PaperInk(scheme).track)
                    .overlay(alignment: .leading) {
                        Capsule().fill(tone)
                            .frame(width: geometry.size.width * Double(min(10000, max(0, bps))) / 10000)
                    }
            }.frame(height: 5).accessibilityHidden(true)
        } else {
            Color.clear.frame(height: 5).accessibilityHidden(true)
        }
    }
    private var metadata: some View {
        VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 3) {
            if hasStatus { FreshnessBadge(value).foregroundStyle(value.isHistorical ? amber : tone) }
            if severity != .normal {
                Text(L(severity == .critical ? "billing.critical" : "billing.warning")).foregroundStyle(tone)
            }
            if value.window.window.resetsAt != nil { ResetLabel(value, compact: true).foregroundStyle(.secondary) }
        }.font(.caption)
    }
}

public struct BillingMetricDetails: View {
    let value: QuotaPresentation
    public init(value: QuotaPresentation) { self.value = value }
    private var scopeNote: String {
        let key = "billing.scope." + value.window.providerId
        return L(key)
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                ProviderMark(providerID: value.window.providerId, size: 30)
                VStack(alignment: .leading) {
                    Text(value.window.accountAlias).font(.headline)
                    Text(ProviderCatalog.identity(for: value.window.providerId).displayName).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(value.window.shortDisplayName).font(.subheadline).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(value.valueHeading).font(.caption).foregroundStyle(.secondary)
                Text(value.number).font(.system(size: 32, weight: .semibold)).monospacedDigit().minimumScaleFactor(0.7)
            }
            if value.visibleBps != nil { QuotaRuler(value) }
            FreshnessBadge(value)
            if let date = value.window.observedAt.flatMap(QuotaRules.date) {
                LabeledContent(L("billing.fetchedAt")) { Text(date, style: .relative) }
            }
            if let date = value.window.window.startsAt.flatMap(QuotaRules.date) {
                if value.window.providerId != "github-actions" {
                    LabeledContent(L("billing.periodStart")) { Text(date, style: .date) }
                }
            }
            if value.window.providerId == "github-actions" {
                if let month = GitHubActionsReporting.queryMonth(value.window) {
                    Text(L("billing.github.monthUTC", month)).font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent(L("billing.github.remaining"), value: L("billing.github.unknownStatus"))
                LabeledContent(L("billing.github.reset"), value: L("billing.github.unknownStatus"))
                LabeledContent(L("billing.github.blocked"), value: L("billing.github.unknownStatus"))
                Text(L("billing.github.semanticsNote")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if value.window.window.resetsAt != nil { ResetLabel(value) }
            if ["vercel", "cloudflare", "replit", "github-actions"].contains(value.window.providerId) {
                Text(scopeNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
