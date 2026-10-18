import Foundation
import Darwin
import QuotaCore
import CryptoKit

public struct TokenUsageLogRoots: Sendable {
    public let claude: [URL]
    public let codex: [URL]
    public init(claude: [URL], codex: [URL]) { self.claude = claude; self.codex = codex }
    /// Called only after the user explicitly enables local transcript usage analysis.
    /// These paths are independent of quota-provider account connections.
    public static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        let claudeHome = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
        let codexHome = environment["CODEX_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? home.appendingPathComponent(".codex")
        return Self(claude: claudeHome.map { [$0.appendingPathComponent("projects")] } ?? [
            home.appendingPathComponent(".claude/projects"), home.appendingPathComponent(".config/claude/projects")],
            codex: [codexHome.appendingPathComponent("sessions"), codexHome.appendingPathComponent("archived_sessions")])
    }
}

public struct TokenUsageScanResult: Sendable {
    public let snapshot: TokenUsageSnapshot
    public let localAnalysis: TokenUsageLocalAnalysis?
    public init(snapshot: TokenUsageSnapshot, localAnalysis: TokenUsageLocalAnalysis?) {
        self.snapshot = snapshot; self.localAnalysis = localAnalysis
    }
}
public enum TokenUsageScanner {
    private struct CachedSource: Sendable {
        let key: String
        let recognizedEvents: Int
        let buckets: [TokenUsageBucket]
        let latest: Date?
        let incomplete: Bool
        let costs: [TokenUsageCostBucket]
        let reasons: [String: Int]
        let readFiles: Int
    }
    private final class NumericCache: @unchecked Sendable {
        let lock = NSLock()
        // At most one aggregate-only entry per source; no paths, request IDs,
        // models or transcript content survive in the in-memory cache.
        private var entries: [TokenUsageAgent: CachedSource] = [:]
        func get(agent: TokenUsageAgent, key: String) -> CachedSource? {
            lock.withLock { entries[agent]?.key == key ? entries[agent] : nil }
        }
        func set(agent: TokenUsageAgent, value: CachedSource) { lock.withLock { entries[agent] = value } }
        func clear() { lock.withLock { entries.removeAll() } }
    }
    private static let cache = NumericCache()
    public static func clearCachedAnalysis() { cache.clear() }
    // A source is still bounded. Large transcript content must not consume the
    // former 512 MiB limit before historical numeric records can be reached.
    public static let defaultByteLimit = 8 * 1024 * 1024 * 1024
    /// Synchronous bounded IO; the host runs it off the main actor. A scan REPLACES
    /// all 400 retained daily buckets, so rescanning a cumulative log cannot add twice.
    public static func scan(roots: TokenUsageLogRoots, timeZone: TimeZone, now: Date = Date(),
                            deviceID: String, epoch: String, sequence: Int64) throws -> TokenUsageSnapshot {
        try scanWithAnalysis(roots: roots, timeZone: timeZone, now: now, deviceID: deviceID, epoch: epoch,
                             sequence: sequence).snapshot
    }
    public static func scanWithAnalysis(roots: TokenUsageLogRoots, timeZone: TimeZone, now: Date = Date(),
                                        deviceID: String, epoch: String, sequence: Int64) throws -> TokenUsageScanResult {
        try analyze(roots: roots, timeZone: timeZone, now: now, deviceID: deviceID, epoch: epoch,
                    sequence: sequence, byteLimit: defaultByteLimit)
    }
    // Small injectable budget exercises the same bounded reader in regression tests.
    static func scan(roots: TokenUsageLogRoots, timeZone: TimeZone, now: Date,
                     deviceID: String, epoch: String, sequence: Int64, byteLimit: Int) throws -> TokenUsageSnapshot {
        try analyze(roots: roots, timeZone: timeZone, now: now, deviceID: deviceID, epoch: epoch,
                    sequence: sequence, byteLimit: byteLimit).snapshot
    }
    static func analyze(roots: TokenUsageLogRoots, timeZone: TimeZone, now: Date,
                         deviceID: String, epoch: String, sequence: Int64, byteLimit: Int) throws -> TokenUsageScanResult {
        let calendar = TokenUsageCalendar.calendar(in: timeZone)
        let since = calendar.date(byAdding: .day, value: -399, to: calendar.startOfDay(for: now))!
        var sources: [TokenUsageSource] = [], buckets: [TokenUsageBucket] = []
        var coverage: [TokenUsageScanCoverage] = [], costs: [TokenUsageCostBucket] = []
        let formatter = ISO8601DateFormatter()
        for agent in TokenUsageAgent.allCases {
            try Task.checkCancellation()
            var accumulator = TokenUsageLogAccumulator(agent: agent)
            var readableFiles = 0, visitedFiles = 0, visitedEntries = 0, scannedBytes = 0
            var seenPaths = Set<String>()
            var seenRoots = Set<String>()
            var files: [(url: URL, root: AllowedRoot, modified: Date)] = []
            var cacheHasher = SHA256()
            func hash(_ value: String) { cacheHasher.update(data: Data(value.utf8)); cacheHasher.update(data: Data([0])) }
            hash(agent.rawValue); hash(timeZone.identifier); hash(TokenUsageCalendar.day(since, in: timeZone))
            hash(String(byteLimit)); hash(TokenUsagePricing.version)
            for configured in agent == .claudeCode ? roots.claude : roots.codex {
                guard configured.isFileURL else { accumulator.markIncomplete("root_unavailable"); continue }
                guard FileManager.default.fileExists(atPath: configured.path) else { continue }
                // Resolve only the explicitly configured log root, not descendant
                // links. Symlinked tool homes are common; their targets remain the
                // only permitted roots. A directory FD pins that boundary for IO.
                let canonical = configured.resolvingSymlinksInPath().standardizedFileURL
                guard seenRoots.insert(canonical.path).inserted else { continue }
                guard let access = try? AllowedRoot(canonical) else {
                    accumulator.markIncomplete("root_unavailable"); continue
                }
                hash(canonical.path)
                var enumerationFailed = false
                guard let enumerator = FileManager.default.enumerator(at: canonical,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey], options: [.skipsHiddenFiles],
                    errorHandler: { _, _ in enumerationFailed = true; return true }) else {
                    accumulator.markIncomplete("root_unavailable"); continue
                }
                for case let file as URL in enumerator {
                    try Task.checkCancellation()
                    visitedEntries += 1
                    if visitedEntries > 50_000 { accumulator.markIncomplete("enumeration_limit"); break }
                    if files.count >= 10_000 { accumulator.markIncomplete("file_limit"); break }
                    guard file.pathExtension == "jsonl" else { continue }
                    let properties = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
                    guard properties?.isRegularFile == true, properties?.isSymbolicLink != true,
                          file.standardizedFileURL.path == file.resolvingSymlinksInPath().path,
                          seenPaths.insert(file.standardizedFileURL.path).inserted else { continue }
                    files.append((file, access, properties?.contentModificationDate ?? .distantPast))
                }
                if enumerationFailed { accumulator.markIncomplete("enumeration_failed") }
            }
            for file in files.sorted(by: { $0.url.path < $1.url.path }) {
                try Task.checkCancellation()
                var info = stat()
                guard lstat(file.url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
                    accumulator.markIncomplete("read_failure"); continue
                }
                hash(file.url.path)
                hash("\(info.st_dev)/\(info.st_ino)/\(info.st_mode)/\(info.st_size)/\(info.st_mtimespec.tv_sec)/\(info.st_mtimespec.tv_nsec)/\(info.st_ctimespec.tv_sec)/\(info.st_ctimespec.tv_nsec)")
            }
            let cacheKey = cacheHasher.finalize().map { String(format: "%02x", $0) }.joined()
            if !accumulator.incomplete, let saved = cache.get(agent: agent, key: cacheKey),
               saved.latest.map({ $0 <= now }) ?? true {
                buckets += saved.buckets; costs += saved.costs
                let status: TokenUsageSource.Status = saved.recognizedEvents == 0 ? .unavailable : saved.incomplete ? .partial : .available
                let diagnostic = status == .unavailable ? (saved.readFiles == 0 ? "logs_unavailable" : "no_usage_records") : saved.incomplete ? "incomplete_scan" : nil
                sources.append(TokenUsageSource(agent: agent, status: status, scannedAt: formatter.string(from: now),
                    latestEventAt: saved.latest.map(formatter.string), diagnostic: diagnostic))
                coverage.append(TokenUsageScanCoverage(agent: agent, discoveredFiles: files.count, readFiles: saved.readFiles,
                    bytesRead: 0, byteLimit: byteLimit, reasons: saved.reasons, reusedUnchangedFiles: true))
                continue
            }
            // Prefer recent logs across all roots so bounded history cannot
            // consume the entire read budget before reaching current usage.
            for file in files.sorted(by: { $0.modified == $1.modified ? $0.url.path < $1.url.path : $0.modified > $1.modified }) {
                    try Task.checkCancellation()
                    visitedFiles += 1
                    guard visitedFiles <= 10_000, scannedBytes < byteLimit else {
                        accumulator.markIncomplete("byte_budget"); break
                    }
                    accumulator.beginFile()
                    do {
                        try readLines(file.url, root: file.root, byteLimit: byteLimit, consumedBytes: &scannedBytes) { line in
                            if let line {
                                autoreleasepool { accumulator.consume(line) }
                            } else { accumulator.markIncomplete("oversized_lines") }
                        }
                        readableFiles += 1
                    } catch is CancellationError { throw CancellationError() }
                    catch ReadError.limit { accumulator.markIncomplete("byte_budget") }
                    catch { accumulator.markIncomplete() }
            }
            let result = accumulator.result(timeZone: timeZone, since: since, through: now)
            try Task.checkCancellation()
            // Retry transient IO/clock failures. Reuse stable parsed gaps only
            // while all file identity/size/mtime/ctime and timezone/retention match.
            if !result.reasons.keys.contains(where: { ["read_failure", "root_unavailable", "enumeration_failed", "future_usage_rows"].contains($0) }) {
                cache.set(agent: agent, value: CachedSource(key: cacheKey, recognizedEvents: accumulator.recognizedEvents,
                    buckets: result.buckets, latest: result.latest, incomplete: result.incomplete,
                    costs: result.costs, reasons: result.reasons, readFiles: readableFiles))
            }
            buckets += result.buckets
            costs += result.costs
            coverage.append(TokenUsageScanCoverage(agent: agent, discoveredFiles: files.count, readFiles: readableFiles,
                bytesRead: scannedBytes, byteLimit: byteLimit, reasons: result.reasons))
            let status: TokenUsageSource.Status = accumulator.recognizedEvents == 0 ? .unavailable : result.incomplete ? .partial : .available
            let diagnostic: String? = status == .unavailable ? (readableFiles == 0 ? "logs_unavailable" : "no_usage_records") : result.incomplete ? "incomplete_scan" : nil
            sources.append(TokenUsageSource(agent: agent, status: status, scannedAt: formatter.string(from: now),
                latestEventAt: result.latest.map(formatter.string), diagnostic: diagnostic))
        }
        let snapshot = TokenUsageSnapshot(sourceDeviceId: deviceID, sourceEpoch: epoch, sourceSequence: sequence,
            capturedAt: formatter.string(from: now), timeZoneIdentifier: timeZone.identifier,
            retainedFromDay: TokenUsageCalendar.day(since, in: timeZone), sources: sources,
            buckets: buckets.sorted { ($0.day, $0.agent.rawValue) < ($1.day, $1.agent.rawValue) })
        _ = try TokenUsageSnapshotCodec.encode(snapshot)
        return TokenUsageScanResult(snapshot: snapshot, localAnalysis: TokenUsageLocalAnalysis(capturedAt: snapshot.capturedAt,
            timeZoneIdentifier: timeZone.identifier, sources: coverage, costs: costs))
    }
    private enum ReadError: Error { case invalidFile, limit, read }
    private final class AllowedRoot {
        let url: URL
        let fd: Int32
        init(_ url: URL) throws {
            let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw ReadError.read }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR else {
                close(descriptor); throw ReadError.invalidFile
            }
            self.url = url; fd = descriptor
        }
        deinit { close(fd) }
        func openFile(_ file: URL) throws -> Int32 {
            let prefix = url.path.hasSuffix("/") ? url.path : url.path + "/"
            guard file.standardizedFileURL.path.hasPrefix(prefix) else { throw ReadError.invalidFile }
            let components = String(file.standardizedFileURL.path.dropFirst(prefix.count)).split(separator: "/")
            guard !components.isEmpty, components.allSatisfy({ $0 != "." && $0 != ".." }) else { throw ReadError.invalidFile }
            var directory = fcntl(fd, F_DUPFD_CLOEXEC, 0)
            guard directory >= 0 else { throw ReadError.read }
            defer { close(directory) }
            for component in components.dropLast() {
                let next = openat(directory, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw ReadError.invalidFile }
                close(directory); directory = next
            }
            let fileFD = openat(directory, String(components.last!), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fileFD >= 0 else { throw ReadError.read }
            return fileFD
        }
    }
    private static func readLines(_ url: URL, root: AllowedRoot, byteLimit: Int, consumedBytes: inout Int, consume: (Data?) -> Void) throws {
        let fd = try root.openFile(url)
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_size >= 0 else { throw ReadError.invalidFile }
        guard info.st_size <= byteLimit - consumedBytes else { throw ReadError.limit }
        // Bound each scan to the original file extent while the agent appends new rows.
        let size = Int(info.st_size)
        var readCount = 0, pending = Data(), buffer = [UInt8](repeating: 0, count: 65_536), discarding = false
        while readCount < size {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &buffer, min(buffer.count, size - readCount))
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw ReadError.read }
            readCount += count; consumedBytes += count
            // Keep at most one bounded line. Discard an oversized line through
            // its newline, then continue; it must not hide later valid records.
            var start = 0
            while start < count {
                let newline = buffer[start..<count].firstIndex(of: 10)
                let end = newline ?? count
                if !discarding {
                    if pending.count + end - start > 2_097_152 {
                        pending.removeAll(keepingCapacity: false); discarding = true; consume(nil)
                    } else { pending.append(contentsOf: buffer[start..<end]) }
                }
                if newline != nil {
                    if !discarding { consume(pending) }
                    pending.removeAll(keepingCapacity: true); discarding = false
                    start = end + 1
                } else { start = count }
            }
        }
        if !discarding, !pending.isEmpty { consume(pending) }
    }
}
