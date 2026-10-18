import Foundation
import QuotaCore

/// Bounded JSON transport for the native API clients. One shared session that
/// refuses redirects (a credential must never follow a 30x to another host),
/// sends no cookies, and caps the accepted response size.
enum NativeHTTP {
    static let maxResponseBytes = 2_097_152

    private final class RedirectRefuser: NSObject, URLSessionTaskDelegate {
        func urlSession(_: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection _: HTTPURLResponse,
                        newRequest _: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration, delegate: RedirectRefuser(), delegateQueue: nil)
    }()

    struct Response {
        let status: Int
        let headers: [AnyHashable: Any]
        let data: Data

        func header(_ name: String) -> String? {
            (headers as NSDictionary).value(forKey: name) as? String
        }
    }

    enum Failure: Error {
        case transport(Error)
        case redirectBlocked
        case httpStatus(Int)
        case payloadTooLarge
    }

    static func request(
        _ method: String, _ url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval = 20, githubRateLimits: Bool = false) async throws -> Response
    {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw Failure.transport(error)
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.transport(URLError(.badServerResponse)) }
        // The delegate refuses redirects before another request can receive
        // these headers. Reject the 3xx response without reading its body.
        if (300..<400).contains(http.statusCode) { throw Failure.redirectBlocked }
        if githubRateLimits {
            var rateHeaders: [String: String] = [:]
            for (key, value) in http.allHeaderFields { rateHeaders[String(describing: key).lowercased()] = String(describing: value) }
            if let retry = GitHubRateLimitFailure.deadline(status: http.statusCode, headers: rateHeaders, receivedAt: Date()) {
                throw GitHubRateLimitFailure(retryNotBefore: retry)
            }
        }
        if http.statusCode != 200 { throw Failure.httpStatus(http.statusCode) }
        if response.expectedContentLength > Int64(maxResponseBytes) { throw Failure.payloadTooLarge }
        let data: Data
        do {
            data = try await collect(bytes)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.transport(error)
        }
        return Response(status: http.statusCode, headers: http.allHeaderFields, data: data)
    }

    /// Consume at most limit + 1 bytes from an async response. The transport
    /// stops reading as soon as the advertised or actual body exceeds the cap.
    static func collect<S: AsyncSequence>(_ bytes: S, limit: Int = maxResponseBytes) async throws -> Data where S.Element == UInt8 {
        var data = Data()
        data.reserveCapacity(min(limit, 65_536))
        for try await byte in bytes {
            guard data.count < limit else { throw Failure.payloadTooLarge }
            data.append(byte)
        }
        return data
    }

    /// Shared status mapping for every native API client.
    static func classify(_ error: Error) -> ProviderFailure {
        switch error {
        case Failure.redirectBlocked, Failure.httpStatus(401):
            return .authRequired
        case Failure.httpStatus(403):
            return .permissionDenied
        case let Failure.httpStatus(status):
            if status == 429 {
                return .rateLimited(seconds: 300)
            }
            return (500...599).contains(status) ? .network : .parseChanged
        case let Failure.transport(underlying as URLError):
            switch underlying.code {
            case .timedOut: return .timeout
            case .cancelled: return .cancelled
            default: return .network
            }
        case Failure.payloadTooLarge:
            return .outputLimit
        default:
            return .parseChanged
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= maxResponseBytes else { throw ProviderFailure.outputLimit }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw ProviderFailure.parseChanged }
    }

    static func parseDouble(_ raw: String?) -> Double? {
        guard let raw, raw.range(of: "^[0-9]+(\\.[0-9]+)?$", options: .regularExpression) != nil else { return nil }
        return Double(raw)
    }
}
