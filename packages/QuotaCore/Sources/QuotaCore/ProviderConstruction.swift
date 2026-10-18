import Foundation

public extension QuotaWindow {
    /// Typed construction for provider adapters that report units other than percent
    /// or confidence weaker than `reported`.
    static func providerValue(
        id: String,
        providerID: String,
        accountID: String,
        alias: String,
        key: String,
        unit: Unit,
        currency: String?,
        availability: Availability = .available,
        remainingBps: Int?,
        amount: String?,
        limit: String?,
        quality: Quality,
        source: SourceMethod,
        outcome: FetchOutcome = .ok,
        observedAt: Date,
        staleAt: Date,
        windowKind: WindowDefinition.Kind,
        duration: Int?,
        resetsAt: Date?,
        startsAt: Date? = nil,
        periodID: String? = nil
    ) -> QuotaWindow {
        let formatter = ISO8601DateFormatter()
        return QuotaWindow(
            id: id,
            providerId: providerID,
            accountId: accountID,
            accountAlias: alias,
            quotaKey: key,
            sharedPoolId: nil,
            unit: unit,
            currency: currency,
            availability: availability,
            remainingBps: remainingBps,
            amount: amount,
            limit: limit,
            quality: quality,
            sourceMethod: source,
            fetchOutcome: outcome,
            observedAt: formatter.string(from: observedAt),
            staleAt: formatter.string(from: staleAt),
            window: WindowDefinition(
                kind: windowKind,
                durationSeconds: duration,
                startsAt: startsAt.map(formatter.string),
                resetsAt: resetsAt.map(formatter.string),
                periodId: periodID
            ),
            history: []
        )
    }
}
