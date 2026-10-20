import Foundation
import QuotaStore

/// Bridges the application-only UIKit adapter to a testable expiration/drain
/// lifecycle. All system begin/end calls remain on the main actor.
@MainActor
public enum PhoneFileTransactionBackgroundAssertion {
    public static func begin(start: (@escaping @MainActor @Sendable () -> Void) -> Int?,
                             end: @escaping @MainActor @Sendable (Int) -> Void) throws -> FileTransactionProtection {
        let assertion = Assertion(end: end)
        let protection = FileTransactionProtection {
            Task { @MainActor in assertion.finish() }
        }
        assertion.identifier = start {
            protection.expireAndDrain()
            // Expiration returns only after unlock/close AND the system end call.
            // The normal queued completion is idempotent and is not needed here.
            assertion.finish()
        }
        guard assertion.identifier != nil, !protection.isExpired else {
            protection.expireAndDrain()
            assertion.finish()
            throw StoreError.unavailable
        }
        return protection
    }

    @MainActor private final class Assertion {
        var identifier: Int?
        let end: @MainActor @Sendable (Int) -> Void
        init(end: @escaping @MainActor @Sendable (Int) -> Void) { self.end = end }
        func finish() {
            guard let identifier else { return }
            self.identifier = nil
            end(identifier)
        }
    }
}
