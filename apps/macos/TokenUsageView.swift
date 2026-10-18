import AppKit
import SwiftUI
import UniformTypeIdentifiers
import QuotaCore
import QuotaDesign

private struct MacTokenReceiptPresentation: Identifiable {
    let id = UUID()
    let data: TokenUsageReceiptData
}

@MainActor
struct TokenUsageView: View {
    @ObservedObject var model: MacModel
    var fixtureMode = false
    var onOpenSettings: () -> Void = {}
    @State private var period = TokenUsagePeriod.week
    @State private var anchor = Date()
    @State private var selected: TokenUsageAgent? = .codex
    @State private var receipt: MacTokenReceiptPresentation?
    @Environment(\.colorScheme) private var scheme

    private var timeZone: TimeZone { TimeZone(identifier: model.tokenUsage?.timeZoneIdentifier ?? model.tokenUsageTimeZoneIdentifier) ?? .current }
    private var summary: TokenUsageSummary { TokenUsageSummary.make(snapshot: model.tokenUsage, period: period, anchor: anchor, timeZone: timeZone) }
    private var stale: Bool { model.tokenUsageIsStale() }

    var body: some View {
        GeometryReader { geometry in
        let wide = geometry.size.width >= 820
        let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 20)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(L("tokenUsage.title")).font(.largeTitle.bold())
                    Spacer()
                    Button { Task { await model.refreshTokenUsage() } } label: {
                        if model.tokenUsageBusy { ProgressView().controlSize(.small) }
                        else { Label(L("island.action.refresh"), systemImage: "arrow.clockwise") }
                    }.buttonStyle(StudioRaisedButtonStyle()).disabled(!model.tokenUsageEnabled || model.tokenUsageBusy || fixtureMode)
                    Button {
                        if let snapshot = model.tokenUsage {
                            receipt = MacTokenReceiptPresentation(data: TokenUsageReceiptData(snapshot: snapshot, summary: summary, period: period, stale: stale))
                        }
                    } label: { Label(L("tokenUsage.share"), systemImage: "square.and.arrow.up") }
                        .buttonStyle(StudioRaisedButtonStyle()).disabled(summary.total == nil || fixtureMode)
                }
                if fixtureMode {
                    ContentUnavailableView(L("island.fixture.modeTitle"), systemImage: "testtube.2", description: Text(L("tokenUsage.fixtureUnavailable")))
                } else {
                    HStack {
                        Label(L(model.tokenUsageEnabled ? "tokenUsage.settings.enabled" : "tokenUsage.settings.disabled"),
                              systemImage: model.tokenUsageEnabled ? "checkmark.shield" : "pause.circle")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Button(L("tokenUsage.settings.open"), action: onOpenSettings)
                            .buttonStyle(StudioRaisedButtonStyle()).accessibilityIdentifier("tokenUsageOpenSettings")
                    }
                    if model.tokenUsageEnabled {
                        layout {
                            VStack(spacing: 18) {
                                TokenUsagePeriodPicker(period: $period, anchor: $anchor, timeZone: timeZone,
                                                       range: TokenUsageText.range(summary, timeZone: timeZone))
                                if let snapshot = model.tokenUsage {
                                    TokenUsageOverviewCard(snapshot: snapshot, summary: summary, timeZone: timeZone, stale: stale)
                                    TokenUsageAgentList(snapshot: snapshot, summary: summary, selected: $selected)
                                } else {
                                    ContentUnavailableView(L("tokenUsage.waiting.title"), systemImage: "chart.bar", description: Text(L("tokenUsage.waiting.mac")))
                                        .frame(maxWidth: .infinity, minHeight: 280)
                                }
                            }.frame(maxWidth: .infinity)
                            if let snapshot = model.tokenUsage {
                                TokenUsageSourceDetails(snapshot: snapshot, summary: summary, selected: selected).frame(width: wide ? 245 : nil)
                            }
                        }
                        if let analysis = model.tokenUsageLocalAnalysis,
                           analysis.capturedAt == model.tokenUsage?.capturedAt {
                            TokenUsageLocalAnalysisView(analysis: analysis, period: period, anchor: anchor, timeZone: timeZone, stale: stale)
                        }
                    }
                    if let message = model.tokenUsageMessage {
                        Label(message, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                    }
                    if let message = model.tokenUsageSyncMessage {
                        Label(message, systemImage: "icloud.slash").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(24).frame(maxWidth: 1200, alignment: .leading)
        }
        }
        .sheet(item: $receipt) { receipt in
            MacTokenReceiptPreview(data: receipt.data)
        }
    }

}

@MainActor
private struct MacTokenReceiptPreview: View {
    let data: TokenUsageReceiptData
    @State private var rendered: NSImage?
    @State private var png: Data?
    @State private var feedback: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(L("tokenUsage.share.title")).font(.title2.bold())
                Spacer()
                Button(L("settings.connections.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                if let rendered {
                    Image(nsImage: rendered).resizable().scaledToFit().frame(maxWidth: 355)
                        .shadow(color: .black.opacity(0.13), radius: 14, y: 9)
                        .padding(20).accessibilityLabel(L("tokenUsage.receipt.preview"))
                } else { ProgressView().padding(50) }
            }.frame(maxHeight: 610)
            HStack(spacing: 12) {
                Button { saveImage() } label: { Label(L("tokenUsage.saveImage"), systemImage: "square.and.arrow.down") }
                    .buttonStyle(.bordered).disabled(png == nil)
                if let rendered {
                    ShareLink(item: Image(nsImage: rendered), preview: SharePreview("Ammo Token Receipt", image: Image(nsImage: rendered))) {
                        Label(L("tokenUsage.systemShare"), systemImage: "square.and.arrow.up")
                    }.buttonStyle(.borderedProminent)
                }
            }
            Text(L("tokenUsage.share.privacy")).font(.caption).foregroundStyle(.secondary)
            if let feedback { Text(feedback).font(.caption).foregroundStyle(.secondary) }
        }.padding(24).frame(width: 470).background(PaperInk(scheme).canvas)
            .task { render() }
    }

    private func render() {
        let renderer = ImageRenderer(content: TokenUsageReceiptView(data: data))
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { feedback = L("tokenUsage.export.failed"); return }
        rendered = NSImage(cgImage: cgImage, size: NSSize(width: TokenUsageReceiptView.width, height: TokenUsageReceiptView.height))
        png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    private func saveImage() {
        guard let png else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Ammo-Token-Receipt.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try png.write(to: url, options: .atomic); feedback = L("tokenUsage.export.saved") }
        catch { feedback = L("tokenUsage.export.failed") }
    }
}
