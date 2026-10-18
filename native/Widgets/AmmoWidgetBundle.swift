import SwiftUI
import WidgetKit
import QuotaWidgets
import QuotaSync
import QuotaCore

private struct PairedWidgetSource: WidgetSnapshotReading {
    func loadWidgetSnapshot() async -> WidgetSnapshotLoad {
        do {
            var cfSnapshot: QuotaCore.Snapshot?
            if PairedEnvironment.cfEnabled, let credentials = try? PairedEnvironment.credentials(),
               let client = try? PairedEnvironment.client(credentials) {
                do { cfSnapshot = try await client.refresh() }
                catch TransportError.rejected(let code) where code == 401 || code == 403 { /* Keep iCloud independent. */ }
                catch { cfSnapshot = try? await client.cached() }
            }
            let snapshot = await PairedEnvironment.cachedSelection(cf: cfSnapshot)
            let fixedWindowIDs = try PairedEnvironment.widgetWindowIDs()
            if !fixedWindowIDs.isEmpty {
                return WidgetSnapshotLoad(snapshot: snapshot, fixedWindowIDs: fixedWindowIDs)
            }
            return WidgetSnapshotLoad(snapshot: snapshot, requiresWindowSelection: true)
        } catch VaultError.locked { return WidgetSnapshotLoad(snapshot: nil, isLocked: true) }
        catch { return WidgetSnapshotLoad(snapshot: nil) }
    }
}
@main
struct AmmoWidgetBundle: WidgetBundle {
    init() {
        // Render entries in the language chosen in the app; the override is
        // shared through the App Group defaults suite.
        if PairedEnvironment.group.hasPrefix("group."), let defaults = UserDefaults(suiteName: PairedEnvironment.group) {
            L10n.install(additionalDefaults: defaults)
        }
    }

    var body: some Widget {
        AmmoGroupLiveActivity()
        AmmoLiveActivity()
        AmmoWidget(provider: QuotaWidgetIntentTimelineProvider(source: PairedWidgetSource()))
    }
}
