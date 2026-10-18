import SwiftUI
import QuotaCore
import QuotaDesign
#if os(iOS)
import UIKit
import Photos
#endif

private struct PhoneTokenReceiptPresentation: Identifiable {
    let id = UUID()
    let data: TokenUsageReceiptData
}

/// The phone renders the paired Mac's verified, redacted aggregates; it never scans logs.
@MainActor
public struct TokenUsagePhoneView: View {
    let snapshot: TokenUsageSnapshot?
    let stale: Bool
    let message: String?
    @State private var period = TokenUsagePeriod.week
    @State private var anchor = Date()
    @State private var selected: TokenUsageAgent?
    @State private var showDetails = false
    @State private var receipt: PhoneTokenReceiptPresentation?
    @Environment(\.colorScheme) private var scheme

    public init(snapshot: TokenUsageSnapshot?, stale: Bool = false, message: String? = nil) {
        self.snapshot = snapshot; self.stale = stale; self.message = message
    }
    private var timeZone: TimeZone { TimeZone(identifier: snapshot?.timeZoneIdentifier ?? "") ?? .current }
    private var summary: TokenUsageSummary { TokenUsageSummary.make(snapshot: snapshot, period: period, anchor: anchor, timeZone: timeZone) }
    private var historical: Bool {
        guard let date = snapshot.flatMap({ QuotaRules.date($0.capturedAt) }) else { return true }
        return stale || Date().timeIntervalSince(date) > 15 * 60
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("tokenUsage.title")).font(.largeTitle.bold())
            if let snapshot {
                TokenUsagePeriodPicker(period: $period, anchor: $anchor, timeZone: timeZone,
                                       range: TokenUsageText.range(summary, timeZone: timeZone))
                TokenUsageOverviewCard(snapshot: snapshot, summary: summary, timeZone: timeZone, stale: historical)
                TokenUsageAgentList(snapshot: snapshot, summary: summary, selected: $selected)
                Button {
                    receipt = PhoneTokenReceiptPresentation(data: TokenUsageReceiptData(snapshot: snapshot, summary: summary, period: period, stale: historical))
                } label: {
                    Label(L("tokenUsage.shareRange"), systemImage: "square.and.arrow.up")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 9)
                }.buttonStyle(.borderedProminent).disabled(summary.total == nil)
                DisclosureGroup(L("tokenUsage.coverage.title")) {
                    Text(L("tokenUsage.phone.scope")).font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                    TokenUsageSourceDetails(snapshot: snapshot, summary: summary, selected: nil).padding(.top, 12)
                }.font(.subheadline)
            } else {
                ContentUnavailableView(L("tokenUsage.waiting.title"), systemImage: "chart.bar", description: Text(L("tokenUsage.waiting.phone")))
                    .frame(maxWidth: .infinity)
            }
            if let message { Label(message, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .onChange(of: selected) { _, value in if value != nil { showDetails = true } }
        .sheet(isPresented: $showDetails, onDismiss: { selected = nil }) {
            if let snapshot {
                NavigationStack {
                    ScrollView { TokenUsageSourceDetails(snapshot: snapshot, summary: summary, selected: selected).padding(20) }
                        .navigationTitle(L("tokenUsage.details"))
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("settings.connections.close")) { showDetails = false } } }
                }.presentationDetents([.medium, .large])
            }
        }
        #if os(iOS)
        .sheet(item: $receipt) { receipt in
            PhoneTokenReceiptPreview(data: receipt.data)
        }
        #endif
    }
}

#if os(iOS)
@MainActor
private struct PhoneTokenReceiptPreview: View {
    let data: TokenUsageReceiptData
    @State private var rendered: UIImage?
    @State private var png: Data?
    @State private var feedback: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                ScrollView {
                    if let rendered {
                        Image(uiImage: rendered).resizable().scaledToFit()
                            .shadow(color: .black.opacity(0.13), radius: 12, y: 8)
                            .padding(.horizontal, 26).padding(.vertical, 16)
                            .accessibilityLabel(L("tokenUsage.receipt.preview"))
                    } else { ProgressView().padding(50) }
                }
                HStack(spacing: 12) {
                    Button { Task { await saveImage() } } label: {
                        Label(L("tokenUsage.saveImage"), systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity).padding(.vertical, 7)
                    }.buttonStyle(.bordered).disabled(png == nil || saving)
                    if let rendered {
                        ShareLink(item: Image(uiImage: rendered), preview: SharePreview("Ammo Token Receipt", image: Image(uiImage: rendered))) {
                            Label(L("tokenUsage.systemShare"), systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity).padding(.vertical, 7)
                        }.buttonStyle(.borderedProminent)
                    }
                }.padding(.horizontal, 20)
                Text(L("tokenUsage.share.privacy")).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let feedback { Text(feedback).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            }
            .padding(.bottom, 18).background(PaperInk(scheme).canvas)
            .navigationTitle(L("tokenUsage.share.title")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("settings.connections.close")) { dismiss() } } }
        }
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        .task { render() }
    }

    private func render() {
        let renderer = ImageRenderer(content: TokenUsageReceiptView(data: data))
        renderer.scale = 2
        guard let image = renderer.uiImage, let encoded = image.pngData() else {
            feedback = L("tokenUsage.export.failed"); return
        }
        rendered = image; png = encoded
    }

    /// This is called only by Save Image. Preview and system sharing never ask for Photos access.
    private func saveImage() async {
        guard let png, !saving else { return }
        saving = true; defer { saving = false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            feedback = L("tokenUsage.photos.denied"); return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: png, options: nil)
            }
            feedback = L("tokenUsage.export.saved")
        } catch { feedback = L("tokenUsage.export.failed") }
    }
}
#endif
