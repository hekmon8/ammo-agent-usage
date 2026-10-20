import Foundation
// The framework also imports under recent macOS SDKs while every BGTask API is
// marked API_UNAVAILABLE(macos); gate on the platform, not on canImport.
#if os(iOS) && canImport(BackgroundTasks)
// BGTask predates Swift concurrency: its types carry no Sendable information,
// and the task object must cross into the MainActor hops below.
@preconcurrency import BackgroundTasks

/// The phone's one background opportunity. iOS wakes the app through the
/// registered app-refresh task at its own learned cadence; the handler reuses the
/// foreground refresh path so verified snapshots and running Live Activities stay
/// current after the app leaves the screen. It never starts a new monitoring
/// session, never polls, and makes no fixed-refresh promise — the system may skip
/// or defer the request.
@MainActor
public enum PhoneBackgroundRefresh {
    /// Must match `BGTaskSchedulerPermittedIdentifiers` in native/Phone/Info.plist.
    public static var taskIdentifier: String? { Bundle.main.bundleIdentifier.map { $0 + ".refresh" } }

    /// Installed by the app host once its sync state is ready. Runs on the main
    /// actor with the same guards as a foreground refresh.
    public static var performRefresh: (@MainActor @Sendable () async -> Void)?

    private static var registered = false

    /// Call once during app launch; handlers must be registered before the app
    /// finishes launching.
    public static func register() {
        guard !registered, let taskIdentifier else { return }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil,
                                        launchHandler: PhoneBackgroundRefresh.handleLaunch)
    }

    /// BGTaskScheduler fires the launch handler — and the expiration handler —
    /// from its own background queue. Under Swift 6 a closure written in this
    /// MainActor-isolated type inherits that isolation, and the entry assertion
    /// traps the process the moment the system calls it, so the handlers must
    /// stay nonisolated and hop to the main actor explicitly.
    nonisolated private static func handleLaunch(_ rawTask: BGTask) {
        guard let task = rawTask as? BGAppRefreshTask else {
            rawTask.setTaskCompleted(success: false)
            return
        }
        let completion = BackgroundTaskCompletion()
        task.expirationHandler = {
            guard completion.expire() else { return }
            Task { @MainActor in
                PhoneBackgroundRefresh.schedule()
                task.setTaskCompleted(success: false)
            }
        }
        let work = Task { @MainActor in
            PhoneBackgroundRefresh.schedule()
            guard !Task.isCancelled else { return }
            await PhoneBackgroundRefresh.performRefresh?()
            guard completion.claim() else { return }
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        completion.attach(work)
    }

    /// Re-arms the request. Safe to call repeatedly; the earliest begin date keeps
    /// the cadence bounded. Submission failures are non-fatal — the system decides.
    public static func schedule(earliestBegin seconds: TimeInterval = 15 * 60) {
        guard let taskIdentifier else { return }
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: seconds)
        try? BGTaskScheduler.shared.submit(request)
    }
}
#endif

/// The system may expire a task while the refresh is still running; exactly one
/// caller may report completion. Expiration before attachment must also cancel
/// the refresh; a late completion cannot report success after system expiry.
final class BackgroundTaskCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    private var work: Task<Void, Never>?

    func attach(_ task: Task<Void, Never>) {
        lock.lock()
        let cancel = claimed
        if !cancel { work = task }
        lock.unlock()
        if cancel { task.cancel() }
    }

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        work = nil
        return true
    }

    func expire() -> Bool {
        lock.lock()
        guard !claimed else { lock.unlock(); return false }
        claimed = true
        let task = work
        work = nil
        lock.unlock()
        task?.cancel()
        return true
    }
}
