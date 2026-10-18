import Foundation
import SwiftUI
import QuotaCore
import QuotaSync
import QuotaPhone
import QuotaDesign

/// Received quotas never enter the paired snapshot, widgets, or Live Activities.
private struct ReceivedShare: Codable, Identifiable {
    var claim: ShareClaim?
    var grant: ShareGrant?
    var projection: ShareProjection?

    var id: String {
        let endpoint = grant?.endpoint ?? claim!.endpoint
        return endpoint.absoluteString + "/" + (grant?.shareId ?? claim!.shareId)
    }
}

@MainActor
struct ReceivedSharesView: View {
    let incomingURL: URL?
    let refreshGeneration: UUID

    @State private var link = ""
    @State private var recipientName = ""
    @State private var invitation: ShareInvitation?
    @State private var entries: [ReceivedShare] = []
    @State private var offlineIDs: Set<String> = []
    @State private var message: String?
    @State private var accessNotice: String?
    @State private var scanning = false
    @State private var busy = false
    @State private var unsaved = false
    @State private var restored = false
    @Environment(\.colorScheme) private var scheme

    private let vault = KeychainVault(service: "QuotaIsland.receivedShares")
    private let account = "recipient-grants"
    private static let preciseDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let dateFormatter = ISO8601DateFormatter()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("phone.shares.intro")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField(L("phone.shares.linkPlaceholder"), text: $link)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                    Button(L("phone.shares.scan")) { scanning = true }
                        .buttonStyle(.bordered)
                }
                Button(L("phone.shares.inspect")) { inspect(link) }
                    .disabled(busy || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let invitation {
                    Text(L("phone.shares.source", invitation.endpoint.host ?? invitation.endpoint.absoluteString))
                        .font(.subheadline.weight(.semibold))
                    Text(L("phone.shares.consent")).font(.caption).foregroundStyle(.secondary)
                    TextField(L("phone.shares.namePlaceholder"), text: $recipientName)
                        .textContentType(.name)
                        .textFieldStyle(.roundedBorder)
                    Button(L("phone.shares.claim")) { Task { await claim(invitation) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!restored || busy || recipientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
            .background(PaperInk(scheme).surface, in: RoundedRectangle(cornerRadius: 20))

            if let accessNotice {
                Label(accessNotice, systemImage: "person.crop.circle.badge.xmark")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
            if let message {
                Label(message, systemImage: "info.circle")
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(PaperInk(scheme).surface, in: RoundedRectangle(cornerRadius: 12))
            }
            HStack {
                Text(L("phone.shares.received")).font(.headline)
                Spacer()
                Button { Task { await refreshAll() } } label: {
                    if busy { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(busy)
                .accessibilityLabel(L("phone.shares.refresh"))
            }
            if entries.isEmpty {
                ContentUnavailableView(L("phone.shares.empty"), systemImage: "person.2")
            }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 10) {
                    if let claim = entry.claim, entry.grant == nil {
                        Label(L("phone.shares.awaitingApproval"), systemImage: "hourglass")
                            .font(.headline)
                        Text(L("phone.shares.verification", claim.verificationCode))
                            .font(.title3.monospacedDigit().weight(.semibold))
                        Text(L("phone.shares.verifyHint"))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(claim.endpoint.host ?? claim.endpoint.absoluteString)
                            .font(.caption2).foregroundStyle(.secondary)
                        if offlineIDs.contains(entry.id) {
                            Label(L("phone.shares.offline"), systemImage: "wifi.slash")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    } else if let projection = entry.projection {
                        Text(projection.label).font(.headline)
                        Text(projection.providerId).font(.caption).foregroundStyle(.secondary)
                        if offlineIDs.contains(entry.id) {
                            Label(L("phone.shares.offlineCached"), systemImage: "wifi.slash")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if let captured = shareDate(projection.capturedAt) {
                            (Text(L("phone.shares.updated") + " ") + Text(captured, style: .relative))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if projection.windows.isEmpty {
                            Text(L("phone.shares.noWindows")).font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(projection.windows.indices, id: \.self) { index in
                            shareWindow(projection.windows[index], offline: offlineIDs.contains(entry.id))
                        }
                    } else {
                        Label(L("phone.shares.loading"), systemImage: "arrow.clockwise")
                            .font(.headline)
                        if offlineIDs.contains(entry.id) {
                            Label(L("phone.shares.offline"), systemImage: "wifi.slash")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(PaperInk(scheme).surface, in: RoundedRectangle(cornerRadius: 20))
            }
        }
        .sheet(isPresented: $scanning) {
            PairingScannerView(
                onPayload: { payload in scanning = false; link = payload; inspect(payload) },
                onUnavailable: { reason in scanning = false; message = reason }
            )
            .ignoresSafeArea()
        }
        .task(id: incomingURL) {
            if let incomingURL { link = incomingURL.absoluteString; inspect(link) }
        }
        .task(id: refreshGeneration) {
            await ReceivedSharesForeground.wait()
            if !restored {
                do {
                    let data = try vault.load(account)
                    let saved = try JSONDecoder().decode([ReceivedShare].self, from: data)
                    guard saved.allSatisfy({ $0.claim != nil || $0.grant != nil }) else {
                        message = L("phone.shares.storageError"); return
                    }
                    entries = saved
                    offlineIDs = Set(saved.map(\.id))
                    if let notice = UserDefaults.standard.string(forKey: "phone.shares.foregroundNotice") {
                        accessNotice = L(notice)
                        UserDefaults.standard.removeObject(forKey: "phone.shares.foregroundNotice")
                    }
                } catch VaultError.locked {
                    message = L("phone.shares.storageError"); return
                } catch VaultError.unavailable {
                    // No stored shares on a fresh install.
                } catch {
                    message = L("phone.shares.storageError"); return
                }
                restored = true
            }
            await refreshAll()
        }
    }

    private func shareWindow(_ window: ShareWindow, offline: Bool) -> some View {
        let stale = offline || window.fetchOutcome != "ok"
            || window.availability == "unavailable"
            || window.staleAt.flatMap(shareDate).map { $0 <= .now } != false
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.quotaKey).font(.subheadline.weight(.medium))
                Spacer()
                if stale {
                    Text(L("phone.shares.stale")).font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
            }
            if window.availability == "unlimited" {
                Text(L("phone.shares.unlimited")).font(.subheadline)
            } else if window.availability == "unavailable" {
                Text(L("phone.shares.unavailable")).font(.subheadline).foregroundStyle(.secondary)
            } else {
                if let bps = window.remainingBps {
                    Text(String(format: "%.1f%%", Double(bps) / 100))
                        .font(.title3.monospacedDigit().weight(.semibold))
                }
                if let amount = window.amount {
                    Text(window.limit.map { L("phone.shares.amountLimit", amount, $0, window.currency ?? window.unit) }
                         ?? L("phone.shares.amount", amount, window.currency ?? window.unit))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let reset = window.resetsAt.flatMap(shareDate) {
                (Text(L("phone.shares.resets") + " ") + Text(reset, style: .relative))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private func shareDate(_ text: String) -> Date? {
        Self.preciseDateFormatter.date(from: text) ?? Self.dateFormatter.date(from: text)
    }

    private func inspect(_ text: String) {
        do {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed) else { throw SyncError.configuration }
            invitation = try ShareInvitation.parse(url)
            message = nil
        } catch {
            invitation = nil
            message = L("phone.shares.invalidLink")
        }
    }

    private func save(_ next: [ReceivedShare]) throws {
        try vault.save(JSONEncoder().encode(next), account: account)
        entries = next
    }

    private func claim(_ invitation: ShareInvitation) async {
        guard restored, !busy else { return }
        busy = true; defer { busy = false }
        do {
            let name = recipientName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            let key = invitation.endpoint.absoluteString + "/" + invitation.shareId
            guard !entries.contains(where: { $0.id == key }) else {
                message = L("phone.shares.alreadyClaimed"); self.invitation = nil; return
            }
            let claim = try await ShareRecipient.claim(invitation: invitation, recipientName: name)
            let next = entries + [ReceivedShare(claim: claim, grant: nil, projection: nil)]
            do {
                try save(next)
                message = L("phone.shares.claimed")
            } catch {
                entries = next
                unsaved = true
                message = L("phone.shares.storageError")
            }
            self.invitation = nil
            link = ""
        } catch {
            message = L("phone.shares.claimError")
        }
    }

    private func refreshAll() async {
        guard restored, !busy else { return }
        busy = true; defer { busy = false }
        if unsaved {
            do {
                try save(entries)
                unsaved = false
            } catch {
                message = L("phone.shares.storageError")
                return
            }
        }
        for entry in entries {
            guard !Task.isCancelled else { return }
            do {
                var updated = entry
                if updated.grant == nil, let claim = updated.claim {
                    guard let grant = try await ShareRecipient.result(claim: claim) else {
                        offlineIDs.remove(entry.id)
                        continue
                    }
                    updated.grant = grant
                    updated.claim = nil
                    try save(entries.map { $0.id == entry.id ? updated : $0 })
                }
                if let grant = updated.grant {
                    updated.projection = try await ShareRecipient.projection(grant: grant)
                    try save(entries.map { $0.id == entry.id ? updated : $0 })
                }
                offlineIDs.remove(entry.id)
            } catch SyncError.unavailable {
                do {
                    try save(entries.filter { $0.id != entry.id })
                    offlineIDs.remove(entry.id)
                    accessNotice = L("phone.shares.revoked")
                } catch { message = L("phone.shares.storageError") }
            } catch TransportError.rejected(let code) where code == 401 || code == 403 || code == 404 {
                do {
                    try save(entries.filter { $0.id != entry.id })
                    offlineIDs.remove(entry.id)
                    accessNotice = L("phone.shares.revoked")
                } catch { message = L("phone.shares.storageError") }
            } catch TransportError.rejected(410) {
                do {
                    try save(entries.filter { $0.id != entry.id })
                    offlineIDs.remove(entry.id)
                    accessNotice = L("phone.shares.deliveryExpired")
                } catch { message = L("phone.shares.storageError") }
            } catch {
                offlineIDs.insert(entry.id)
                message = L("phone.shares.refreshError")
            }
        }
    }
}

/// Refresh grants even when the user's own-quota tab is on screen. This uses
/// only recipient credentials, and never touches paired snapshot state.
@MainActor
enum ReceivedSharesForeground {
    private static var inFlight: Task<Void, Never>?
    private static let vault = KeychainVault(service: "QuotaIsland.receivedShares")
    private static let account = "recipient-grants"

    static func wait() async { await inFlight?.value }

    static func refresh() async {
        if let inFlight { await inFlight.value; return }
        let task = Task { await perform() }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private static func perform() async {
        guard let data = try? vault.load(account),
              var entries = try? JSONDecoder().decode([ReceivedShare].self, from: data),
              entries.allSatisfy({ $0.claim != nil || $0.grant != nil }) else { return }
        for entry in entries {
            do {
                var updated = entry
                if updated.grant == nil, let claim = updated.claim {
                    guard let grant = try await ShareRecipient.result(claim: claim) else { continue }
                    updated.grant = grant
                    updated.claim = nil
                    try store(entries.map { $0.id == entry.id ? updated : $0 })
                    entries = entries.map { $0.id == entry.id ? updated : $0 }
                }
                if let grant = updated.grant {
                    updated.projection = try await ShareRecipient.projection(grant: grant)
                    let next = entries.map { $0.id == entry.id ? updated : $0 }
                    try store(next)
                    entries = next
                }
            } catch SyncError.unavailable {
                discard(entry, from: &entries, notice: "phone.shares.revoked")
            } catch TransportError.rejected(let code) where code == 401 || code == 403 || code == 404 {
                discard(entry, from: &entries, notice: "phone.shares.revoked")
            } catch TransportError.rejected(410) {
                discard(entry, from: &entries, notice: "phone.shares.deliveryExpired")
            } catch {
                // Keep cached readings and credentials until a later foreground.
            }
        }
    }

    private static func discard(_ entry: ReceivedShare, from entries: inout [ReceivedShare], notice: String) {
        let next = entries.filter { $0.id != entry.id }
        do {
            try store(next)
            entries = next
            UserDefaults.standard.set(notice, forKey: "phone.shares.foregroundNotice")
        } catch {
            // A failed Keychain update must not pretend that access was removed.
        }
    }

    private static func store(_ entries: [ReceivedShare]) throws {
        try vault.save(JSONEncoder().encode(entries), account: account)
    }
}
