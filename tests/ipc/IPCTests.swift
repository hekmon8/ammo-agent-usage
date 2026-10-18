import Foundation
import XCTest
import QuotaIPC
import QuotaStore
import Darwin

final class IPCTests: XCTestCase {
    func testProviderExecCannotInheritRefreshConnection() async throws {
        let directory = URL(fileURLWithPath: "/tmp/qi-exec-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lease = try CollectorLease(directory: directory)
        let server = RefreshServer()
        try await server.start(directory: directory) { _ in
            // Plain posix_spawn deliberately has no close-all-fds flag: only the
            // server's FD_CLOEXEC boundary can protect the in-flight peer socket.
            let script = """
            import os, socket, stat, sys
            for fd in range(3, 1024):
                try:
                    if not stat.S_ISSOCK(os.fstat(fd).st_mode): continue
                    s = socket.socket(fileno=fd)
                    name = s.getsockname()
                    s.detach()
                    if name == sys.argv[1]: sys.exit(1)
                except OSError: pass
            """
            let values = ["/usr/bin/python3", "-c", script, directory.appendingPathComponent("refresh.sock").path]
            let allocated = values.map { strdup($0)! }
            defer { allocated.forEach { free($0) } }
            var arguments: [UnsafeMutablePointer<CChar>?] = allocated.map { $0 } + [nil]
            var environment: [UnsafeMutablePointer<CChar>?] = [nil]
            var child: pid_t = 0
            guard posix_spawn(&child, values[0], nil, nil, &arguments, &environment) == 0 else { throw IPCError.failed }
            var result: Int32 = 0
            guard waitpid(child, &result, 0) == child, result == 0 else { throw IPCError.failed }
        }
        do {
            try await RefreshClient.request(directory: directory, provider: nil, timeout: 10)
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
        withExtendedLifetime(lease) {}
    }
    func testRefreshUsesExistingSameUserCollectorAndStops() async throws {
        let directory = URL(fileURLWithPath: "/tmp/qi-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lease = try CollectorLease(directory: directory)
        let server = RefreshServer()
        actor Requests { var values: [String?] = []; func add(_ value: String?) { values.append(value) } }
        let requests = Requests()
        try await server.start(directory: directory) { await requests.add($0) }
        try await RefreshClient.request(directory: directory, provider: "codex", timeout: 2)
        let values = await requests.values
        XCTAssertEqual(values, ["codex"])
        await server.stop()
        do { try await RefreshClient.request(directory: directory, provider: nil, timeout: 1); XCTFail("collector restarted") } catch {}
        withExtendedLifetime(lease) {}
    }
    func testCallerCancellationClosesBoundedRequest() async throws {
        let directory = URL(fileURLWithPath: "/tmp/qi-cancel-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lease = try CollectorLease(directory: directory)
        let server = RefreshServer()
        try await server.start(directory: directory) { _ in try await Task.sleep(for: .seconds(30)) }
        let task = Task { try await RefreshClient.request(directory: directory, provider: nil, timeout: 60) }
        try await Task.sleep(for: .milliseconds(100))
        let start = Date(); task.cancel()
        do { try await task.value; XCTFail("cancel ignored") } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        await server.stop(); withExtendedLifetime(lease) {}
    }

}
