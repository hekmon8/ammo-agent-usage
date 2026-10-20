import Foundation

/// A host-owned execution assertion. Expiration denies admission/commit, but
/// protection ends only after the transaction has released its file descriptor.
public final class FileTransactionProtection: @unchecked Sendable {
    private let condition = NSCondition()
    private var expired = false
    private var finished = false
    private var activeTransaction = false
    private var onFinish: (@Sendable () -> Void)?
    private var mutationCheck: (@Sendable () throws -> Void)?

    public init(onFinish: @escaping @Sendable () -> Void = {}) { self.onFinish = onFinish }

    static func checkingMutations(_ check: @escaping @Sendable () throws -> Void) -> FileTransactionProtection {
        let protection = FileTransactionProtection()
        protection.mutationCheck = check
        return protection
    }

    public var isExpired: Bool {
        condition.lock(); defer { condition.unlock() }
        return expired
    }

    var isTransactionActive: Bool {
        condition.lock(); defer { condition.unlock() }
        return activeTransaction
    }

    public func expire() {
        condition.lock(); defer { condition.unlock() }
        expired = true
    }

    /// Called synchronously by the app's expiration callback. The owner must
    /// release/close its descriptor before signaling finish; draining never
    /// requires a MainActor hop from the owner. Before admission, no drain is needed.
    public func expireAndDrain() {
        condition.lock()
        expired = true
        while activeTransaction { condition.wait() }
        let completion = takeCompletion()
        condition.unlock()
        completion?()
    }

    func beginTransaction() throws {
        condition.lock(); defer { condition.unlock() }
        guard !expired && !finished && !activeTransaction else { throw StoreError.unavailable }
        activeTransaction = true
    }

    func check() throws {
        condition.lock(); defer { condition.unlock() }
        guard !expired && !finished else { throw StoreError.unavailable }
    }

    func checkMutation() throws {
        try check()
        try mutationCheck?()
        try check()
    }

    func finish() {
        condition.lock()
        activeTransaction = false
        let completion = takeCompletion()
        condition.broadcast()
        condition.unlock()
        completion?()
    }

    func finishIfUnclaimed() {
        condition.lock()
        guard !activeTransaction else { condition.unlock(); return }
        let completion = takeCompletion()
        condition.unlock()
        completion?()
    }

    private func takeCompletion() -> (@Sendable () -> Void)? {
        guard !finished else { return nil }
        finished = true
        let completion = onFinish
        onFinish = nil
        return completion
    }
}

final class FileTransactionProtectionProvider: @unchecked Sendable {
    // Scoped fault injection follows the calling task through actor hops without
    // changing the application's process-wide assertion provider.
    @TaskLocal static var override: (@Sendable () throws -> FileTransactionProtection)?
    private let lock = NSLock()
    private var factory: (@Sendable () throws -> FileTransactionProtection)?

    func install(_ begin: @escaping @Sendable () throws -> FileTransactionProtection) {
        lock.lock(); defer { lock.unlock() }
        factory = begin
    }

    func begin() throws -> FileTransactionProtection {
        if let override = Self.override { return try override() }
        lock.lock()
        let begin = factory
        lock.unlock()
        if let begin { return try begin() }
        #if os(iOS)
        // Apps must install protection before any transaction. WidgetKit grants
        // extensions their own execution opportunity and forbids UIApplication.
        guard Bundle.main.bundleURL.pathExtension == "appex" else { throw StoreError.unavailable }
        #endif
        return FileTransactionProtection()
    }
}
