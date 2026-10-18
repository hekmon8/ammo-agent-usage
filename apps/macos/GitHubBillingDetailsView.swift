import Foundation
import QuotaCore
import QuotaDesign
import QuotaProviders
import SwiftUI

/// An explicit local read of the saved connection. Budget configurations are
/// deliberately kept out of quota snapshots and synced projections.
@MainActor
struct GitHubBillingDetailsView: View {
    @ObservedObject var model: MacModel
    let connection: ProviderConnectionSummary
    @Environment(\.dismiss) private var dismiss
    @State private var report: GitHubBillingReport?
    @State private var errorStatus: LocalizedStatus?
    @State private var request: Task<Void, Never>?

    init(model: MacModel, connection: ProviderConnectionSummary, initialReport: GitHubBillingReport? = nil) {
        self.model = model
        self.connection = connection
        _report = State(initialValue: initialReport)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("billing.github.detailsTitle")).studioType(.title)
                    Text(connection.accountAlias).studioType(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").padding(5) }
                    .buttonStyle(StudioRaisedButtonStyle(iconOnly: true))
                    .accessibilityLabel(L("settings.connections.close"))
            }.padding(22)
            StudioDivider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if request != nil {
                        ProgressView(L("billing.github.loading")).frame(maxWidth: .infinity, minHeight: 160)
                    } else if let report {
                        expense(report)
                        StudioDivider()
                        budgets(report)
                    } else if let errorStatus {
                        Label(errorStatus.text, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
            StudioDivider()
            HStack {
                Spacer()
                Button(L("billing.github.refresh")) { refresh() }
                    .buttonStyle(StudioRaisedButtonStyle())
                    .disabled(request != nil || model.connecting || model.shareBusy || !isEnabled)
            }.padding(18)
        }
        .frame(width: 580, height: 620)
        .onAppear { refresh() }
        .onDisappear { request?.cancel() }
    }

    private var isEnabled: Bool {
        model.providerConnections.contains { $0.id == connection.id && $0.providerID == "github-actions" && $0.isEnabled }
    }

    private func expense(_ report: GitHubBillingReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent(L("billing.github.account"), value: report.owner)
            Text(L("billing.github.monthlyNetExpense")).studioType(.section)
            Text(expenseAmount(report)).font(.system(size: 32, weight: .semibold)).monospacedDigit()
            if report.expenseFailure != nil {
                Text(L("billing.github.expenseUnavailable")).studioType(.caption).foregroundStyle(.secondary)
            }
            Text(monthLabel(report)).studioType(.caption).foregroundStyle(.secondary)
            LabeledContent(L("billing.github.remaining"), value: L("billing.github.unknownStatus"))
            LabeledContent(L("billing.github.reset"), value: L("billing.github.unknownStatus"))
            LabeledContent(L("billing.github.blocked"), value: L("billing.github.unknownStatus"))
            Text(L("billing.github.semanticsNote")).studioType(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L("billing.scope.github-actions")).studioType(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func budgets(_ report: GitHubBillingReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("billing.github.budgetsTitle")).studioType(.section)
            Text(L("billing.github.budgetsLocalOnly")).studioType(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            switch report.budgetState {
            case .available:
                if report.budgets.isEmpty {
                    budgetMessage("billing.github.budgets.availableEmpty")
                } else {
                    budgetRows(report)
                }
            case .personalNotSupported:
                budgetMessage("billing.github.budgets.personalNotSupported")
            case .permissionDenied:
                budgetMessage("billing.github.budgets.permissionDenied")
            case .unavailable:
                budgetMessage("billing.github.budgets.unavailable")
            case .incomplete:
                budgetMessage("billing.github.budgets.incomplete")
            }
            Text(L("billing.github.preventionNote")).studioType(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func budgetRows(_ report: GitHubBillingReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(report.budgets, id: \.id) { budget in
                VStack(alignment: .leading, spacing: 5) {
                    LabeledContent(L("billing.github.budgetCap"), value: money(budget.amount, currency: "USD"))
                    Text(L(budget.preventsFurtherUsage ? "billing.github.preventionConfigured" : "billing.github.preventionNotConfigured"))
                        .studioType(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).studioSurface(radius: 8)
            }
        }
    }

    private func budgetMessage(_ key: String) -> some View {
        Text(L(key)).studioType(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func expenseAmount(_ report: GitHubBillingReport) -> String {
        guard let cost = report.usage.cost else { return "—" }
        return money(cost.used, currency: cost.currency)
    }

    private func money(_ amount: Double, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.roundingMode = .down
        return (formatter.string(from: NSNumber(value: amount)) ?? "—") + " " + currency
    }

    private func monthLabel(_ report: GitHubBillingReport) -> String {
        guard let period = report.usage.cost?.periodID else { return L("billing.github.monthUnknown") }
        let month = String(period.suffix(7))
        guard month.range(of: "^[0-9]{4}-(0[1-9]|1[0-2])$", options: .regularExpression) != nil else {
            return L("billing.github.monthUnknown")
        }
        return L("billing.github.monthUTC", month)
    }

    private func refresh() {
        guard request == nil, !model.connecting, !model.shareBusy, isEnabled else { return }
        report = nil
        errorStatus = nil
        request = Task {
            defer { request = nil }
            do {
                let result = try await model.githubBillingDetails(connectionID: connection.id)
                try Task.checkCancellation()
                report = result
            } catch {
                if !Task.isCancelled { errorStatus = GitHubBillingReader.errorStatus(error) }
            }
        }
    }
}
