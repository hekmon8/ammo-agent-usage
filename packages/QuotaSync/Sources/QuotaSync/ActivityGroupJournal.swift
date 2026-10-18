import Foundation

/// Scope-bound recovery metadata. Neither credentials nor APNs token bytes are stored here.
public struct ActivityGroupJournal: Codable, Sendable, Equatable {
    public struct Registration: Codable, Sendable, Equatable {
        public var commandID: String
        public var expectedDisplayRevision: Int64
        public var expectedRegistrationRevision: Int64
        public var tokenHash: String
        /// Frozen request clock makes a lost response retry byte-for-byte equivalent.
        public var preparedAt: Date
        public init(displayRevision: Int64, registrationRevision: Int64, tokenHash: String, preparedAt: Date = .now) {
            commandID = UUID().uuidString; expectedDisplayRevision = displayRevision
            expectedRegistrationRevision = registrationRevision; self.tokenHash = tokenHash; self.preparedAt = preparedAt
        }
    }
    public struct Fence: Codable, Sendable, Equatable {
        public var commandID: String
        public var expectedRevision: Int64
        public var abandon: Bool
        public init(expectedRevision: Int64, abandon: Bool) {
            commandID = UUID().uuidString; self.expectedRevision = expectedRevision; self.abandon = abandon
        }
    }
    public var displayRevision: Int64 = 0
    public var registrationRevision: Int64 = 0
    public var groupID: String?
    public var windowIDs: [String] = []
    public var sourceDeviceID = ""
    public var sourceEpoch = ""
    public var endsAt = Date.distantPast
    public var localCreated = false
    public var pendingStop = false
    public var fence: Fence?
    public var registration: Registration?
    public init() {}
    public var requiresAbandonment: Bool { groupID != nil && !localCreated }
    public mutating func begin(groupID: String, windowIDs: [String], sourceDeviceID: String, sourceEpoch: String, endsAt: Date) {
        self.groupID = groupID; self.windowIDs = windowIDs; self.sourceDeviceID = sourceDeviceID
        self.sourceEpoch = sourceEpoch; self.endsAt = endsAt; localCreated = false
        registrationRevision = 0; registration = nil
    }
    public mutating func stopIntent() { pendingStop = true }
    public mutating func acknowledgeFence(displayRevision: Int64) {
        self.displayRevision = displayRevision; groupID = nil; windowIDs = []
        registrationRevision = 0; localCreated = false; pendingStop = false; fence = nil; registration = nil
    }
}
