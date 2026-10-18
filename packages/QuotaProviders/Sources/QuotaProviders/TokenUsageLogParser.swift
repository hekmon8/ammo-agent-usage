import Foundation
import CoreFoundation
import QuotaCore

/// Native, offline JSONL normalization. Only numeric usage and ephemeral dedupe keys survive a line.
/// This does not invoke an agent, read auth files, make a provider request, or infer usage from quotas.
public struct TokenUsageLogAccumulator {
    private struct Event {
        let date: Date
        let tokens: TokenUsageCounts
        var model: String? = nil
        var requestInput: Int64? = nil
        var cacheWriteOneHour: Int64? = nil
        var cacheTTLConflict = false
        // At most eight known distributions per message. Exceeding the bound
        // makes its price unknown; no earlier constraint is silently discarded.
        var knownCacheTTLs: [Int64: Int64] = [:]
        var requestTokens: TokenUsageCounts? = nil
    }
    private struct Request { let event: Event; let cumulative: TokenUsageCounts }
    private struct CodexFile {
        var session: String?
        var forked = false
        var requestSession: String?
        var turnModels: [String: String] = [:]
        var activeContextModel: String?
    }
    public let agent: TokenUsageAgent
    private var events: [String: Event] = [:]
    private var codexCounters: [String: [String: Event]] = [:]
    private var distinctCodexCounters = 0
    private var codexRequests: [String: [String: Request]] = [:]
    // Bounded by distinct request IDs. A conflicted identity never becomes
    // trusted again when another replay happens to match its first payload.
    private var codexConflictedRequests: [String: Set<String>] = [:]
    private var distinctRequests = 0
    private var codex = CodexFile()
    public private(set) var incomplete = false
    public private(set) var recognizedEvents = 0
    public private(set) var reasons: [String: Int] = [:]
    public init(agent: TokenUsageAgent) { self.agent = agent }
    public mutating func beginFile() { codex = CodexFile() }
    public mutating func markIncomplete(_ reason: String = "read_failure") {
        incomplete = true; reasons[reason, default: 0] += 1
        // An unreadable/skipped row may have changed the active model. Keep
        // numeric counters, but never carry legacy fallback pricing across a gap.
        if agent == .codex { codex.activeContextModel = nil }
    }

    public mutating func consume(_ line: Data) {
        guard !line.isEmpty else { return }
        guard line.count <= 2_097_152,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { markIncomplete("malformed_rows"); return }
        switch agent {
        case .claudeCode: claude(object)
        case .codex: consumeCodex(object)
        }
    }
    private static func integer(_ value: Any?) -> Int64? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue.rounded() == value.doubleValue,
              value.doubleValue >= 0, value.doubleValue <= 2_251_799_813_685_247 else { return nil }
        return value.int64Value
    }
    private static func optionalInteger(_ object: [String: Any], _ key: String) -> Int64? {
        object[key] == nil ? 0 : integer(object[key])
    }
    private mutating func insert(_ key: String, date: Date, counts: TokenUsageCounts, mergeStreaming: Bool = false,
                                 model: String? = nil, cacheWriteOneHour: Int64? = nil) {
        guard counts.isValid, key.utf8.count <= 1024 else { markIncomplete("invalid_usage_rows"); return }
        recognizedEvents += 1
        if let old = events[key] {
            if mergeStreaming {
                // Claude logs streaming snapshots of the same message. Keep final counters,
                // with original attribution; never add partial and final representations.
                var ttlConflict = old.cacheTTLConflict
                var known = old.knownCacheTTLs
                if let hour = cacheWriteOneHour {
                    for (previousWrite, previousHour) in known {
                        if counts.cacheWrite >= previousWrite {
                            ttlConflict = ttlConflict || hour < previousHour || counts.cacheWrite - hour < previousWrite - previousHour
                        } else {
                            ttlConflict = ttlConflict || previousHour < hour || previousWrite - previousHour < counts.cacheWrite - hour
                        }
                    }
                    if known[counts.cacheWrite] == nil && known.count >= 8 { ttlConflict = true }
                    else if known[counts.cacheWrite] == nil { known[counts.cacheWrite] = hour }
                }
                let aggregateWrite = max(old.tokens.cacheWrite, counts.cacheWrite)
                let hour = known[aggregateWrite]
                events[key] = Event(date: min(old.date, date), tokens: TokenUsageCounts(
                    nonCachedInput: max(old.tokens.nonCachedInput, counts.nonCachedInput),
                    cacheRead: max(old.tokens.cacheRead, counts.cacheRead),
                    cacheWrite: max(old.tokens.cacheWrite, counts.cacheWrite), output: max(old.tokens.output, counts.output)),
                    model: old.model == model ? model : nil,
                    cacheWriteOneHour: ttlConflict ? nil : hour, cacheTTLConflict: ttlConflict,
                    knownCacheTTLs: known)
            }
            return
        }
        guard events.count < 200_000 else { markIncomplete("event_limit"); return }
        events[key] = Event(date: date, tokens: counts, model: model, cacheWriteOneHour: cacheWriteOneHour,
            knownCacheTTLs: cacheWriteOneHour.map { [counts.cacheWrite: $0] } ?? [:])
    }
    private mutating func claude(_ object: [String: Any]) {
        guard object["type"] as? String == "assistant", let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return }
        guard let id = message["id"] as? String, !id.isEmpty,
              let timestamp = object["timestamp"] as? String, let date = QuotaRules.date(timestamp),
              let input = Self.integer(usage["input_tokens"]), let output = Self.integer(usage["output_tokens"]),
              let read = Self.optionalInteger(usage, "cache_read_input_tokens"),
              let write = Self.optionalInteger(usage, "cache_creation_input_tokens") else { markIncomplete("invalid_usage_rows"); return }
        // Anthropic input_tokens EXCLUDES both cache categories. Anthropic message IDs
        // identify the response even when requestId is absent in a streaming row.
        var hour: Int64? = write == 0 ? 0 : nil
        if let creation = usage["cache_creation"] as? [String: Any],
           let five = Self.optionalInteger(creation, "ephemeral_5m_input_tokens"),
           let one = Self.optionalInteger(creation, "ephemeral_1h_input_tokens"), five + one == write { hour = one }
        insert("claude/" + id, date: date,
               counts: TokenUsageCounts(nonCachedInput: input, cacheRead: read, cacheWrite: write, output: output),
               mergeStreaming: true, model: Self.model(message["model"]), cacheWriteOneHour: hour)
    }
    private static func model(_ value: Any?) -> String? {
        guard let value = value as? String,
              value.range(of: "^[a-z0-9][a-z0-9._-]{0,99}$", options: .regularExpression) != nil else { return nil }
        return value
    }
    private static func identity(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 160 else { return nil }
        return value
    }
    private static func fingerprint(_ value: TokenUsageCounts) -> String {
        "\(value.nonCachedInput)/\(value.cacheRead)/\(value.cacheWrite)/\(value.output)"
    }
    private static func codexUsage(_ raw: [String: Any]) -> TokenUsageCounts? {
        guard let input = integer(raw["input_tokens"]), let output = integer(raw["output_tokens"]),
              let read = optionalInteger(raw, "cached_input_tokens"),
              let write = optionalInteger(raw, "cache_write_input_tokens"), read + write <= input,
              let total = optionalInteger(raw, "total_tokens"), raw["total_tokens"] == nil || total == input + output,
              let reasoning = optionalInteger(raw, "reasoning_output_tokens"), reasoning <= output else { return nil }
        // Input INCLUDES cached reads/writes; reasoning is a subset of output.
        return TokenUsageCounts(nonCachedInput: input - read - write, cacheRead: read, cacheWrite: write, output: output)
    }
    private mutating func consumeCodex(_ object: [String: Any]) {
        let isContext = object["type"] as? String == "turn_context"
        if isContext { codex.activeContextModel = nil }
        guard let payload = object["payload"] as? [String: Any] else {
            if isContext { markIncomplete("invalid_usage_rows") }
            return
        }
        if object["type"] as? String == "session_meta" {
            guard let id = payload["id"] as? String, !id.isEmpty, id.utf8.count <= 160 else { markIncomplete("invalid_usage_rows"); return }
            // Codex may persist copied ancestor metadata inside a fork. The first
            // session_meta is canonical; later rows must never replace its identity.
            guard codex.session == nil else { return }
            codex.session = id
            codex.requestSession = Self.identity(payload["session_id"]) ?? id
            let source = payload["source"] as? [String: Any]
            codex.forked = ["forked_from_id", "forkedFromId", "parent_session_id", "parentSessionId"].contains { payload[$0] is String }
                || source?["subagent"] != nil
                || payload["source"] as? String == "subagent" || payload["history_base_thread_id"] != nil
                || payload["subagent_history_start_ordinal"] != nil || payload["history_base"] != nil || payload["historyBase"] != nil
            return
        }
        if object["type"] as? String == "turn_context" {
            // Legacy token_count lacks a turn ID. Bind only to the preceding
            // context in this file; an absent/invalid context clears the model.
            codex.activeContextModel = Self.model(payload["model"] ?? payload["model_name"])
            if let turn = Self.identity(payload["turn_id"]), payload["model"] != nil || payload["model_name"] != nil {
                if codex.turnModels.count < 10_000 || codex.turnModels[turn] != nil {
                    codex.turnModels[turn] = Self.model(payload["model"] ?? payload["model_name"])
                }
                else { markIncomplete("event_limit") }
            }
            return
        }
        if object["type"] as? String == "token_usage_record" {
            guard let session = codex.session,
                  let thread = Self.identity(payload["thread_id"]), thread == session,
                  payload["session_id"] == nil || Self.identity(payload["session_id"]) == codex.requestSession else {
                markIncomplete("unowned_request_rows"); return
            }
            guard let response = Self.identity(payload["response_id"]),
                  let timestamp = object["timestamp"] as? String, let date = QuotaRules.date(timestamp),
                  let usage = (payload["usage"] as? [String: Any]).flatMap(Self.codexUsage),
                  let total = (payload["thread_token_usage"] as? [String: Any]).flatMap(Self.codexUsage),
                  total.nonCachedInput >= usage.nonCachedInput, total.cacheRead >= usage.cacheRead,
                  total.cacheWrite >= usage.cacheWrite, total.output >= usage.output else {
                markIncomplete("invalid_usage_rows"); return
            }
            let model = payload["model"] != nil || payload["model_name"] != nil
                ? Self.model(payload["model"] ?? payload["model_name"])
                : Self.identity(payload["turn_id"]).flatMap { codex.turnModels[$0] }
            let event = Event(date: date, tokens: usage, model: model,
                              requestInput: usage.nonCachedInput + usage.cacheRead + usage.cacheWrite)
            recognizedEvents += 1
            if codexConflictedRequests[session]?.contains(response) == true {
                markIncomplete("conflicting_request_rows"); return
            }
            if let old = codexRequests[session]?[response] {
                guard old.event.tokens == usage, old.cumulative == total else {
                    codexConflictedRequests[session, default: []].insert(response)
                    markIncomplete("conflicting_request_rows"); return
                }
                // Replayed/restamped responses retain their original date. Conflicting
                // model evidence remains unpriced instead of borrowing a known model.
                codexRequests[session]?[response] = Request(event: Event(date: min(old.event.date, date), tokens: usage,
                    model: old.event.model == model ? model : nil, requestInput: event.requestInput), cumulative: total)
            } else {
                guard distinctRequests < 200_000 else { markIncomplete("event_limit"); return }
                codexRequests[session, default: [:]][response] = Request(event: event, cumulative: total)
                distinctRequests += 1
            }
            return
        }
        guard object["type"] as? String == "event_msg", payload["type"] as? String == "token_count" else { return }
        // Forked rollouts can re-stamp inherited events with the child's time.
        // Without stable response IDs the inherited/native boundary is ambiguous.
        // Owned request-ledger rows above remain usable; ambiguous legacy fork
        // and subagent rows cannot prove where inherited history ends.
        guard !codex.forked else { markIncomplete("ambiguous_fork_rows"); return }
        // Null info is an ordinary rate-limit-only notification, not a zero usage record.
        guard let info = payload["info"] as? [String: Any] else { return }
        guard let session = codex.session, let timestamp = object["timestamp"] as? String,
              let date = QuotaRules.date(timestamp), let raw = info["total_token_usage"] as? [String: Any],
              raw["total_tokens"] != nil, let total = Self.codexUsage(raw) else { markIncomplete("invalid_usage_rows"); return }
        // Codex input includes cached input; reasoning is already inside output.
        // Cache writes are validated as another subset of inclusive input.
        recognizedEvents += 1
        let fingerprint = Self.fingerprint(total)
        let last = (info["last_token_usage"] as? [String: Any]).flatMap(Self.codexUsage)
        let model = info["model"] != nil || info["model_name"] != nil
            ? Self.model(info["model"] ?? info["model_name"])
            : (payload["turn_id"] != nil
                ? Self.identity(payload["turn_id"]).flatMap { codex.turnModels[$0] }
                : codex.activeContextModel)
        if let existing = codexCounters[session]?[fingerprint] {
            // A replay may re-stamp a copied event. Keep its earliest original
            // attribution and never treat the emission timestamp as request identity.
            let sameRequest = existing.requestTokens == last
            let merged = Event(date: min(existing.date, date), tokens: total,
                model: existing.model == model ? model : nil,
                requestInput: sameRequest ? existing.requestInput : nil,
                requestTokens: sameRequest ? existing.requestTokens : nil)
            codexCounters[session]?[fingerprint] = merged
        } else {
            guard distinctCodexCounters < 200_000 else { markIncomplete("event_limit"); return }
            codexCounters[session, default: [:]][fingerprint] = Event(date: date, tokens: total, model: model,
                requestInput: last.map { $0.nonCachedInput + $0.cacheRead + $0.cacheWrite }, requestTokens: last)
            distinctCodexCounters += 1
        }
    }
    public func result(timeZone: TimeZone, since: Date, through: Date) -> (buckets: [TokenUsageBucket], latest: Date?, incomplete: Bool, costs: [TokenUsageCostBucket], reasons: [String: Int]) {
        var totals: [String: TokenUsageCounts] = [:]
        var partial = incomplete
        var diagnostics = reasons
        func gap(_ reason: String) { partial = true; diagnostics[reason, default: 0] += 1 }
        var latest: Date?
        var normalized = Array(events.values)
        for (session, counters) in codexCounters {
            if !(codexConflictedRequests[session]?.isEmpty ?? true) {
                // Conflicting cumulative boundaries cannot safely identify a
                // legacy prefix/mirror. Exclude this session's legacy counters
                // rather than reintroducing a tombstoned request through them.
                for event in counters.values where event.tokens.total > 0 { gap("unreconciled_legacy_rows") }
                continue
            }
            let requests = Array(codexRequests[session]?.values ?? Dictionary<String, Request>().values)
            let firstLedger = requests.min { $0.event.date < $1.event.date }
            let firstRequest = firstLedger?.event.date
            let mirrors = Set(requests.map { Self.fingerprint($0.cumulative) })
            var highWater = TokenUsageCounts.zero
            for event in counters.values.sorted(by: { ($0.date, $0.tokens.total) < ($1.date, $1.tokens.total) }) {
                let total = event.tokens
                guard total.nonCachedInput >= highWater.nonCachedInput, total.cacheRead >= highWater.cacheRead,
                      total.cacheWrite >= highWater.cacheWrite, total.output >= highWater.output else {
                    // Rewind/reset/replay makes attribution ambiguous. Keep the
                    // monotonic high-water mark rather than counting old work again.
                    gap("counter_rewinds"); continue
                }
                let delta = TokenUsageCounts(nonCachedInput: total.nonCachedInput - highWater.nonCachedInput,
                    cacheRead: total.cacheRead - highWater.cacheRead, cacheWrite: total.cacheWrite - highWater.cacheWrite,
                    output: total.output - highWater.output)
                highWater = total
                if mirrors.contains(Self.fingerprint(total)) { continue }
                if let firstRequest, event.date >= firstRequest {
                    // Without a response identity after ledger adoption, a legacy
                    // delta may already be covered by a ledger row. Keep it unknown.
                    if delta.total > 0 { gap("unreconciled_legacy_rows") }; continue
                }
                if let firstLedger {
                    let accumulated = firstLedger.cumulative, request = firstLedger.event.tokens
                    // A legacy prefix must fit the request ledger's inherited
                    // baseline in every component. Otherwise its counter scope
                    // differs and adding it would invent/double-count work.
                    guard total.nonCachedInput <= accumulated.nonCachedInput - request.nonCachedInput,
                          total.cacheRead <= accumulated.cacheRead - request.cacheRead,
                          total.cacheWrite <= accumulated.cacheWrite - request.cacheWrite,
                          total.output <= accumulated.output - request.output else {
                        if delta.total > 0 { gap("unreconciled_legacy_rows") }; continue
                    }
                }
                normalized.append(Event(date: event.date, tokens: delta, model: event.model,
                    requestInput: event.requestTokens == delta ? event.requestInput : nil))
            }
        }
        for (session, requests) in codexRequests {
            normalized += requests.filter { codexConflictedRequests[session]?.contains($0.key) != true }.values.map(\.event)
        }
        var costs: [String: (usd: Double, priced: Int64, unknown: Int64)] = [:]
        // One thread-local formatter per result, not one formatter allocation
        // for every historical request in a multi-gigabyte cold scan.
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = TokenUsageCalendar.calendar(in: timeZone)
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = timeZone; dayFormatter.dateFormat = "yyyy-MM-dd"
        for event in normalized {
            guard event.date <= through else { gap("future_usage_rows"); continue }
            latest = max(latest ?? event.date, event.date)
            guard event.date >= since else { continue }
            let day = dayFormatter.string(from: event.date)
            guard let sum = (totals[day] ?? .zero).adding(event.tokens) else { gap("aggregate_overflow"); continue }
            totals[day] = sum
            let price = TokenUsagePricing.standardUSD(agent: agent, model: event.model, counts: event.tokens,
                requestInput: event.requestInput, cacheWriteOneHour: event.cacheWriteOneHour)
            var cost = costs[day] ?? (0, 0, 0)
            if let price { cost.usd += price; cost.priced += event.tokens.total }
            else { cost.unknown += event.tokens.total }
            costs[day] = cost
        }
        return (totals.keys.sorted().map { TokenUsageBucket(day: $0, agent: agent, tokens: totals[$0]!) }, latest, partial,
                costs.keys.sorted().map { let cost = costs[$0]!; return TokenUsageCostBucket(day: $0, agent: agent,
                    standardUSD: cost.priced > 0 ? cost.usd : nil, pricedTokens: cost.priced, unpricedTokens: cost.unknown) }, diagnostics)
    }
}
