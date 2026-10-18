import Foundation
import SwiftUI
import QuotaCore
import QuotaDesign

/// The same native view renders the lock-screen card and synthetic QA previews.
public struct ActivityGroupCardView: View {
    public let descriptors: [ActivityGroupDescriptor]
    public let content: ActivityGroupContent
    public let endsAt: Int64
    public let options: ActivityDisplayOptions
    public let remoteUpdates: Bool
    public let systemIsStale: Bool
    @Environment(\.colorScheme) private var scheme

    public init(descriptors: [ActivityGroupDescriptor], content: ActivityGroupContent, endsAt: Int64,
                options: ActivityDisplayOptions = .init(), remoteUpdates: Bool = false, systemIsStale: Bool = false) {
        self.descriptors = descriptors; self.content = content; self.endsAt = endsAt
        self.options = options; self.remoteUpdates = remoteUpdates; self.systemIsStale = systemIsStale
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(L("widget.activity.group.title"), systemImage: "capsule.fill")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 4)
                    Text(L(remoteUpdates ? (content.bundleRevision > 0 ? "widget.activity.group.remote" : "widget.activity.group.waiting") : "widget.activity.group.local"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(Array(descriptors.enumerated()), id: \.element.windowID) { index, descriptor in
                    if index > 0 { Divider() }
                    let row = content.rows.first { $0.windowID == descriptor.windowID }
                    let presentation = ActivityDisplaySemantics(
                        remainingBps: row?.remainingBps, displayState: row?.displayState ?? "unavailable",
                        observedAt: row?.observedAt, staleAt: row?.staleAt, resetsAt: row?.resetsAt,
                        endsAt: endsAt, now: Int64(context.date.timeIntervalSince1970),
                        systemIsStale: systemIsStale && (row?.staleAt.map { $0 <= Int64(context.date.timeIntervalSince1970) } ?? true))
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            ProviderBrandAsset(providerID: descriptor.providerID).frame(width: 16, height: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ProviderCatalog.identity(for: descriptor.providerID).displayName)
                                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                                if options.showWindowName {
                                    Text(descriptor.title + (descriptor.accountOrdinal.map { " · " + L("widget.activity.group.account", $0) } ?? ""))
                                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            Spacer(minLength: 4)
                            Text(presentation.number).font(.system(.title2, design: .rounded, weight: .semibold))
                                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                                .foregroundStyle(presentation.visualState.color(for: scheme))
                        }
                        if options.showProgress, let bps = presentation.remainingBps {
                            ProgressView(value: Double(bps), total: 10_000)
                                .tint(presentation.visualState.color(for: scheme)).accessibilityHidden(true)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Label(presentation.status, systemImage: presentation.symbol).lineLimit(2)
                            Spacer(minLength: 0)
                            if options.showObservationTime, let observedAt = row?.observedAt {
                                Text(L("widget.activity.observed.short", Date(timeIntervalSince1970: Double(observedAt)).formatted(date: .omitted, time: .shortened)))
                                    .lineLimit(1)
                            }
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#if os(iOS) && canImport(ActivityKit)
@preconcurrency import ActivityKit
import WidgetKit

public struct QuotaGroupActivityAttributes: ActivityAttributes, Sendable {
    public typealias ContentState = ActivityGroupContent
    public let sessionID, sourceDeviceID, sourceEpoch: String
    public let endsAt: Int64
    public let descriptors: [ActivityGroupDescriptor]
    public let displayOptions: ActivityDisplayOptions
    public let remoteUpdates: Bool

    public init(sessionID: String, sourceDeviceID: String, sourceEpoch: String, endsAt: Int64,
                descriptors: [ActivityGroupDescriptor], displayOptions: ActivityDisplayOptions, remoteUpdates: Bool) {
        self.sessionID = sessionID; self.sourceDeviceID = sourceDeviceID; self.sourceEpoch = sourceEpoch
        self.endsAt = endsAt; self.descriptors = descriptors; self.displayOptions = displayOptions; self.remoteUpdates = remoteUpdates
    }
}

@available(iOSApplicationExtension 17.0, *)
public struct AmmoGroupLiveActivity: Widget {
    public init() {}
    public var body: some WidgetConfiguration {
        ActivityConfiguration(for: QuotaGroupActivityAttributes.self) { context in
            ActivityGroupCardView(descriptors: context.attributes.descriptors, content: context.state,
                                  endsAt: context.attributes.endsAt, options: context.attributes.displayOptions,
                                  remoteUpdates: context.attributes.remoteUpdates, systemIsStale: context.isStale)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .activityBackgroundTint(Color(uiColor: .secondarySystemBackground))
                .widgetURL(URL(string: "quotaisland://monitor"))
        } dynamicIsland: { context in
            let first = context.attributes.descriptors.first
            let row = context.state.rows.first { $0.windowID == first?.windowID }
            let presentation = ActivityDisplaySemantics(remainingBps: row?.remainingBps,
                displayState: row?.displayState ?? "unavailable", observedAt: row?.observedAt,
                staleAt: row?.staleAt, resetsAt: row?.resetsAt, endsAt: context.attributes.endsAt,
                now: Int64(Date.now.timeIntervalSince1970))
            return DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    ActivityGroupCardView(descriptors: context.attributes.descriptors, content: context.state,
                                          endsAt: context.attributes.endsAt, options: context.attributes.displayOptions,
                                          remoteUpdates: context.attributes.remoteUpdates, systemIsStale: context.isStale)
                        .environment(\.colorScheme, .dark)
                }
            } compactLeading: {
                if let first {
                    HStack(spacing: 4) {
                        ProviderBrandAsset(providerID: first.providerID).frame(width: 16, height: 16)
                        Text(first.title).font(.caption2).lineLimit(1).frame(maxWidth: 72)
                    }
                } else { Image(systemName: "capsule.fill") }
            } compactTrailing: {
                HStack(spacing: 3) {
                    ActivityQuotaGauge(number: presentation.number, remainingBps: presentation.remainingBps,
                        color: presentation.visualState.color(for: .dark), style: context.attributes.displayOptions.compactStyle)
                    if context.attributes.descriptors.count > 1 { Text(L("widget.activity.group.more", context.attributes.descriptors.count - 1)) }
                }.font(.caption2).foregroundStyle(presentation.visualState.color(for: .dark))
            } minimal: {
                Text(context.attributes.descriptors.count > 1 ? "2" : "1").font(.caption2.weight(.semibold))
            }
            .widgetURL(URL(string: "quotaisland://monitor"))
        }
    }
}

@MainActor
public final class QuotaGroupActivityCoordinator {
    private let registrar: any ActivityTokenRegistering
    private var observers: [String: [Task<Void, Never>]] = [:]
    public var onActivityStateChanged: (() -> Void)?
    public init(tokenRegistrar: any ActivityTokenRegistering) { registrar = tokenRegistrar }

    public static func isRunning(_ activity: Activity<QuotaGroupActivityAttributes>, now: Date = .now) -> Bool {
        guard activity.attributes.endsAt > Int64(now.timeIntervalSince1970) else { return false }
        switch activity.activityState { case .active, .stale, .pending: return true; default: return false }
    }

    @discardableResult
    public func start(attributes: QuotaGroupActivityAttributes, content: ActivityGroupContent) throws -> Bool {
        guard ActivityGroupContent.validID(attributes.sessionID), ActivityGroupContent.validID(attributes.sourceDeviceID),
              ActivityGroupContent.validID(attributes.sourceEpoch), attributes.descriptors.map(\.windowID) == content.rows.map(\.windowID),
              attributes.endsAt > Int64(Date.now.timeIntervalSince1970),
              attributes.endsAt <= Int64(Date.now.addingTimeInterval(8 * 60 * 60).timeIntervalSince1970),
              !Activity<QuotaGroupActivityAttributes>.activities.contains(where: { Self.isRunning($0) }) else { throw ActivityGroupError.invalidAttributes }
        guard try JSONEncoder().encode(attributes).count + JSONEncoder().encode(content).count < 4 * 1024 else { throw ActivityGroupError.payloadTooLarge }
        let activity = try Activity.request(attributes: attributes,
            content: ActivityContent(state: content, staleDate: content.staleDate(endsAt: attributes.endsAt)),
            pushType: attributes.remoteUpdates ? .token : nil)
        observe(activity); return true
    }

    public func updateLocal(sessionID: String, content: ActivityGroupContent) async {
        guard let activity = Activity<QuotaGroupActivityAttributes>.activities.first(where: { $0.attributes.sessionID == sessionID }),
              Self.isRunning(activity), !activity.attributes.remoteUpdates,
              activity.attributes.descriptors.map(\.windowID) == content.rows.map(\.windowID) else { return }
        await activity.update(ActivityContent(state: content, staleDate: content.staleDate(endsAt: activity.attributes.endsAt)))
    }

    public func end(sessionID: String) async {
        observers.removeValue(forKey: sessionID)?.forEach { $0.cancel() }
        if let activity = Activity<QuotaGroupActivityAttributes>.activities.first(where: { $0.attributes.sessionID == sessionID }) {
            await activity.end(ActivityContent(state: activity.content.state, staleDate: nil), dismissalPolicy: .immediate)
        }
        await registrar.endActivity(sessionID: sessionID); onActivityStateChanged?()
    }
    public func endAll() async {
        for activity in Activity<QuotaGroupActivityAttributes>.activities { await end(sessionID: activity.attributes.sessionID) }
    }
    public func recoverExistingActivities() {
        for activity in Activity<QuotaGroupActivityAttributes>.activities where Self.isRunning(activity) { observe(activity) }
    }
    private func observe(_ activity: Activity<QuotaGroupActivityAttributes>) {
        let id = activity.attributes.sessionID
        guard observers[id] == nil else { return }
        let registrar = registrar
        let tokenTask = Task {
            for await token in activity.pushTokenUpdates { await registrar.replacePushToken(token, sessionID: id) }
        }
        let lifecycle = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                self?.onActivityStateChanged?()
                if state == .ended || state == .dismissed {
                    await registrar.endActivity(sessionID: id)
                    self?.observers.removeValue(forKey: id)?.forEach { $0.cancel() }
                    return
                }
            }
        }
        observers[id] = [tokenTask, lifecycle]
    }
}
#endif
