import Foundation

/// Where the sync Worker runs. Both modes speak the identical end-to-end
/// encrypted snapshot protocol (`contracts/openapi.json`); only the endpoint
/// and who operates the Worker differ. Display names resolve through the
/// shared localization tables (`settings.sync.officialName` /
/// `settings.sync.selfHostName` / `phone.sync.mode.*`), never a hardcoded
/// string here.
public enum SyncServiceMode: String, Codable, Sendable, CaseIterable {
    case official
    case selfHosted
}

/// Open-source builds have no hosted service by default. Distributors can opt
/// in with QuotaHostedSyncEndpoint in the app's Info.plist.
public enum SyncServiceCatalog {
    public static var officialEndpoint: URL? {
        configuredEndpoint(Bundle.main.object(forInfoDictionaryKey: "QuotaHostedSyncEndpoint") as? String)
    }

    public static var availableModes: [SyncServiceMode] {
        officialEndpoint == nil ? [.selfHosted] : SyncServiceMode.allCases
    }

    public static var defaultMode: SyncServiceMode { officialEndpoint == nil ? .selfHosted : .official }

    public static func configuredEndpoint(_ value: String?) -> URL? {
        guard let value, !value.isEmpty, !value.contains("$("),
              let endpoint = URL(string: value), endpoint.port == nil,
              (try? SyncTransport(baseURL: endpoint)) != nil else { return nil }
        return endpoint
    }

    /// Strict origin match so the official label never attaches to look-alike
    /// hosts, explicit ports, subpaths, or non-HTTPS schemes.
    public static func isOfficial(_ endpoint: URL, officialEndpoint: URL? = SyncServiceCatalog.officialEndpoint) -> Bool {
        guard let officialEndpoint,
              (try? SyncTransport(baseURL: endpoint)) != nil,
              endpoint.host?.lowercased() == officialEndpoint.host?.lowercased(),
              endpoint.port == officialEndpoint.port else { return false }
        return true
    }

    public static func endpoint(for mode: SyncServiceMode, custom: URL? = nil) -> URL? {
        switch mode {
        case .official: return officialEndpoint
        case .selfHosted: return custom
        }
    }
}
