import Darwin
import Foundation
import XCTest
@testable import QuotaProviders

final class NativeHTTPBoundaryTests: XCTestCase {
    private struct GeneratedBytes: AsyncSequence {
        typealias Element = UInt8
        let count: Int

        struct Iterator: AsyncIteratorProtocol {
            let count: Int
            var position = 0

            mutating func next() async -> UInt8? {
                guard position < count else { return nil }
                position += 1
                return 65
            }
        }

        func makeAsyncIterator() -> Iterator { Iterator(count: count) }
    }

    func testStreamingBodyStopsAtFirstByteOverLimit() async throws {
        let exact = try await NativeHTTP.collect(GeneratedBytes(count: 64), limit: 64)
        XCTAssertEqual(exact.count, 64)
        do {
            _ = try await NativeHTTP.collect(GeneratedBytes(count: 1_000_000), limit: 64)
            XCTFail("oversized response accepted")
        } catch NativeHTTP.Failure.payloadTooLarge {}
    }

    func testAdvertisedOversizeIsRejectedBeforeBodyRead() async throws {
        let server = try OneShotServer(response: "HTTP/1.1 200 OK\r\nContent-Length: 2097153\r\nConnection: close\r\n\r\n",
            bodyBytes: NativeHTTP.maxResponseBytes + 1)
        let serving = server.start()
        do {
            _ = try await NativeHTTP.request("GET", server.url)
            XCTFail("oversized response accepted")
        } catch NativeHTTP.Failure.payloadTooLarge {}
        await serving.value
    }

    func testAuthorizationRedirectIsRefused() async throws {
        let server = try OneShotServer(response: "HTTP/1.1 302 Found\r\nLocation: https://example.invalid/receive\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        let serving = server.start()
        do {
            _ = try await NativeHTTP.request("GET", server.url, headers: ["Authorization": "Bearer synthetic-test-token"])
            XCTFail("credential redirect accepted")
        } catch NativeHTTP.Failure.redirectBlocked {}
        await serving.value
    }
}

private final class OneShotServer: @unchecked Sendable {
    let socketFD: Int32
    let url: URL
    let response: Data

    init(response: String, bodyBytes: Int = 0) throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: in_addr_t(0x7f000001).bigEndian)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EIO)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &length)
            }
        }
        guard named == 0, let url = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/") else {
            Darwin.close(fd)
            throw POSIXError(.EIO)
        }
        socketFD = fd
        self.url = url
        self.response = Data(response.utf8) + Data(repeating: 65, count: bodyBytes)
    }

    deinit { Darwin.close(socketFD) }

    func start() -> Task<Void, Never> {
        Task.detached {
            let client = Darwin.accept(self.socketFD, nil, nil)
            guard client >= 0 else { return }
            defer { Darwin.close(client) }
            var request = [UInt8](repeating: 0, count: 4096)
            _ = Darwin.read(client, &request, request.count)
            var noSigpipe: Int32 = 1
            _ = Darwin.setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe,
                socklen_t(MemoryLayout<Int32>.size))
            self.response.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var sent = 0
                while sent < raw.count {
                    let count = Darwin.write(client, base.advanced(by: sent), raw.count - sent)
                    guard count > 0 else { break }
                    sent += count
                }
            }
        }
    }
}
