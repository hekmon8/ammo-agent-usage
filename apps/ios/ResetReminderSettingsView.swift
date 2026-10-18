import SwiftUI
import QuotaCore

/// Separate per-device opt-in; does not enable APNs or any provider sync.
@MainActor
public struct ResetReminderSettingsView: View {
    @ObservedObject private var coordinator: ResetReminderCoordinator
    public init(coordinator: ResetReminderCoordinator) { self.coordinator = coordinator }
    private var toggleKey: String {
        #if os(macOS)
        "resetReminder.toggle.mac"
        #else
        "resetReminder.toggle.phone"
        #endif
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(L(toggleKey), isOn: Binding(
                get: { coordinator.settings.enabled },
                set: { enabled in Task { await coordinator.setEnabled(enabled) } }
            ))
            Picker(L("resetReminder.lead"), selection: Binding(
                get: { coordinator.settings.leadMinutes },
                set: { minutes in Task { await coordinator.setLeadMinutes(minutes) } }
            )) {
                ForEach(ResetReminderSettings.leadChoices, id: \.self) { minutes in
                    Text(L("resetReminder.minutes", minutes)).tag(minutes)
                }
            }.disabled(!coordinator.settings.enabled)
            Text(coordinator.status.text).font(.caption).foregroundStyle(.secondary)
            Text(L("resetReminder.deviceScope")).font(.caption).foregroundStyle(.secondary)
            DisclosureGroup(L("resetReminder.details")) {
                Text(L("resetReminder.footer")).font(.caption).foregroundStyle(.secondary)
            }.font(.caption)
        }
    }
}
