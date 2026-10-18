import Foundation
import QuotaCore

/// Missing preference shows all providers, including newly connected providers.
/// An explicit empty selection hides every provider. Unknown IDs survive reconnects.
public struct IslandProviderSelection: Equatable, Sendable {
    public static let preferenceKey = "quota.island.providers.v1"
    public var selected: Set<String>?
    public init(stored: [String]?) { selected = stored.map(Set.init) }
    public func includes(_ providerID: String) -> Bool { selected?.contains(providerID) ?? true }
    public func filter(_ windows: [QuotaWindow]) -> [QuotaWindow] { windows.filter { includes($0.providerId) } }
    public mutating func set(_ providerID: String, visible: Bool, available: [String]) {
        if selected == nil { selected = Set(available) }
        if visible { selected?.insert(providerID) } else { selected?.remove(providerID) }
    }
}
