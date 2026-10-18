import Foundation

/// Antigravity quota through Google's cloud-code endpoints. The imported
/// access token is never refreshed: an expired or rejected token requires
/// re-importing the OAuth file. The project ID from the import gates every
/// read, matching the read-only flow.
enum AntigravityUsageReader {
    private static let endpoint = URL(string: "https://cloudcode-pa.googleapis.com")!

    private struct ModelQuotaResponse: Decodable {
        struct QuotaInfo: Decodable {
            let remainingFraction: Double?
            let resetTime: String?
        }
        struct Model: Decodable {
            let displayName: String?
            let label: String?
            let quotaInfo: QuotaInfo?
        }
        let models: [String: Model]?
    }

    private struct BucketResponse: Decodable {
        struct Bucket: Decodable {
            let modelId: String?
            let remainingFraction: Double?
            let resetTime: String?
        }
        let buckets: [Bucket]?
    }

    static func fetch(_ credential: NativeProviderCredential) async throws -> NativeUsage {
        let stored = try AntigravityCredentialImport.storedOAuth(from: credential)
        if let milliseconds = stored.expiryDateMilliseconds,
           Date(timeIntervalSince1970: milliseconds / 1000) <= Date() {
            throw NativeProviderAPIError.credentialRejected
        }
        guard !stored.projectID.isEmpty else { throw NativeProviderAPIError.credentialRejected }
        let headers = [
            "Authorization": "Bearer " + stored.accessToken,
            "Content-Type": "application/json",
            "User-Agent": "antigravity",
        ]
        var modelsData: Data?
        do {
            let modelsBody = try JSONSerialization.data(withJSONObject: ["project": stored.projectID])
            modelsData = try await post("/v1internal:fetchAvailableModels", modelsBody, headers: headers).data
        } catch let failure as NativeHTTP.Failure {
            // A 403 on the model catalog degrades to the bucket endpoint only.
            if case .httpStatus(403) = failure {} else { throw failure }
        }
        // When the catalog is unavailable or every model reports a full quota,
        // cross-check with the bucket endpoint so a stuck catalog cannot hide
        // real usage.
        let allFull: Bool
        if let modelsData,
           let models = try? NativeHTTP.decode(ModelQuotaResponse.self, from: modelsData).models {
            allFull = !models.isEmpty && models.values.allSatisfy { ($0.quotaInfo?.remainingFraction ?? 1) >= 0.999 }
        } else {
            allFull = false
        }
        var bucketsData: Data?
        if modelsData == nil || allFull {
            bucketsData = try? await post("/v1internal:retrieveUserQuota",
                                          try JSONSerialization.data(withJSONObject: ["project": stored.projectID]),
                                          headers: headers).data
        }
        return try parse(modelsData: modelsData, bucketsData: bucketsData, stored: stored)
    }

    static func parse(modelsData: Data?, bucketsData: Data?, stored: AntigravityCredentialImport.StoredOAuth) throws -> NativeUsage {
        var quotas: [String: (remaining: Double, reset: Date?)] = [:]
        if let modelsData,
           let models = try? NativeHTTP.decode(ModelQuotaResponse.self, from: modelsData).models {
            for (modelID, model) in models {
                guard let remaining = model.quotaInfo?.remainingFraction else { continue }
                quotas[modelID] = (remaining, NativeAPIParsing.date(model.quotaInfo?.resetTime))
            }
        }
        if let bucketsData,
           let buckets = try? NativeHTTP.decode(BucketResponse.self, from: bucketsData).buckets {
            for bucket in buckets {
                guard let modelID = bucket.modelId, let remaining = bucket.remainingFraction else { continue }
                let reset = NativeAPIParsing.date(bucket.resetTime)
                if let existing = quotas[modelID] {
                    quotas[modelID] = existing.remaining <= remaining
                        ? existing : (remaining, reset)
                } else {
                    quotas[modelID] = (remaining, reset)
                }
            }
        }
        guard !quotas.isEmpty else { throw NativeProviderAPIError.parseFailure }

        var usage = NativeUsage(updatedAt: Date())
        var geminiPool: [NativeUsage.Window] = []
        var claudeGPTPool: [NativeUsage.Window] = []
        for (modelID, quota) in quotas {
            let window = NativeUsage.Window(
                id: modelID,
                usedPercent: NativeAPIParsing.clampPercent((1 - quota.remaining) * 100),
                windowMinutes: nil, resetsAt: quota.reset)
            let lower = modelID.lowercased()
            if lower.contains("lite") || lower.contains("autocomplete") || lower.hasPrefix("tab_") || lower.contains("image") {
                continue
            }
            if lower.contains("gemini") {
                geminiPool.append(window)
            } else if lower.contains("claude") || lower.contains("gpt") || lower.contains("openai") {
                claudeGPTPool.append(window)
            }
            // Named buckets only surface when the provider reports real usage;
            // a fully free model row is not a measured 0% window.
            if quota.remaining < 0.999 {
                usage.extraWindows.append(window)
            }
        }
        usage.primary = geminiPool.min(by: { $0.usedPercent > $1.usedPercent })
        usage.secondary = claudeGPTPool.min(by: { $0.usedPercent > $1.usedPercent })
        guard usage.primary != nil || usage.secondary != nil else {
            throw NativeProviderAPIError.parseFailure
        }
        usage.identity = .init(email: Self.email(fromIDToken: stored.idToken), organization: stored.projectID)
        if usage.identity.email == nil {
            usage.identitySeed = NativeAPIParsing.legacyCredentialsSeed(
                provider: "antigravity", values: ["accessToken": stored.accessToken, "projectID": stored.projectID])
        }
        return usage
    }

    private static func post(_ path: String, _ body: Data, headers: [String: String]) async throws -> NativeHTTP.Response {
        do {
            return try await NativeHTTP.request("POST", endpoint.appendingPathComponent(path), headers: headers, body: body)
        } catch let failure as NativeHTTP.Failure {
            if case .httpStatus(401) = failure { throw NativeProviderAPIError.credentialRejected }
            if case .httpStatus(403) = failure { throw NativeProviderAPIError.permissionDenied }
            throw failure
        }
    }

    /// The email claim inside the OAuth id_token identifies the account
    /// without any extra network call.
    static func email(fromIDToken raw: String?) -> String? {
        guard let raw else { return nil }
        let parts = raw.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONDecoder().decode([String: String].self, from: data),
              let email = claims["email"], email.contains("@") else { return nil }
        return email
    }
}
