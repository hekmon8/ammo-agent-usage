import Foundation
import MCP
import QuotaQuery

public struct QuotaMCPServer: Sendable {
    public let directory: URL
    public init(directory: URL = QuotaQuery.defaultDirectory) { self.directory = directory }

    public func run() async throws {
        let query = QuotaQuery(directory: directory)
        let server = Server(name: "quota-island", version: QuotaQuery.schemaVersion,
                            capabilities: .init(resources: .init(), tools: .init()), configuration: .strict)
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: [
                Tool(name: "quota_list", description: "Read quota windows from the latest local snapshot. No refresh is performed.", inputSchema: try! schema("quota-list-input.schema"), annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false), outputSchema: try! schema("quota-query-output.schema")),
                Tool(name: "quota_get", description: "Read one quota window from the latest local snapshot.", inputSchema: try! schema("quota-get-input.schema"), annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false), outputSchema: try! schema("quota-query-output.schema")),
                Tool(name: "quota_history", description: "Read bounded history embedded in the latest local snapshot.", inputSchema: try! schema("quota-history-input.schema"), annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false), outputSchema: try! schema("quota-query-output.schema")),
                Tool(name: "quota_health", description: "Read local snapshot health without secrets or paths.", inputSchema: try! schema("quota-health-input.schema"), annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false), outputSchema: try! schema("quota-query-output.schema"))
            ])
        }
        await server.withMethodHandler(CallTool.self) { request in
            do {
                let response: String
                switch request.name {
                case "quota_list":
                    let arguments = try object(request.arguments)
                    try rejectUnknown(arguments, allowed: ["providerId", "includeStale"])
                    let provider = try optionalString(arguments, "providerId")
                    let includeStale = try optionalBool(arguments, "includeStale") ?? true
                    response = try json(query.list(providerId: provider, includeStale: includeStale))
                case "quota_get":
                    let arguments = try object(request.arguments)
                    try rejectUnknown(arguments, allowed: ["windowId"])
                    response = try json(query.get(windowId: try requiredString(arguments, "windowId")))
                case "quota_history":
                    let arguments = try object(request.arguments)
                    try rejectUnknown(arguments, allowed: ["windowId", "range"])
                    response = try json(query.history(windowId: try requiredString(arguments, "windowId"), range: try parseRange(requiredString(arguments, "range"))))
                case "quota_health":
                    let arguments = try object(request.arguments)
                    try rejectUnknown(arguments, allowed: [])
                    response = try json(query.health())
                default: throw MCPInputError("Unknown read-only tool: \(request.name)")
                }
                return .init(content: [.text(response)], isError: false)
            } catch {
                return .init(content: [.text(errorText(error))], isError: true)
            }
        }
        await server.withMethodHandler(ListResources.self) { _ in
            .init(resources: [
                Resource(name: "Latest quota snapshot", uri: "quota://snapshot/latest", description: "Latest redacted quota projection.", mimeType: "application/json"),
                Resource(name: "Quota providers", uri: "quota://providers", description: "Provider identifiers in the latest snapshot.", mimeType: "application/json")
            ])
        }
        await server.withMethodHandler(ReadResource.self) { request in
            let value: String
            switch request.uri {
            case "quota://snapshot/latest": value = try json(query.status())
            case "quota://providers": value = try json(query.providers())
            default: throw MCPInputError("Unknown resource: \(request.uri)")
            }
            return .init(contents: [.text(value, uri: request.uri, mimeType: "application/json")])
        }
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}

private func schema(_ name: String) throws -> Value { try JSONDecoder().decode(Value.self, from: QuotaQuerySchemas.data(named: name)) }
private func json(_ value: some Encodable) throws -> String { String(decoding: try JSONEncoder.sorted.encode(value), as: UTF8.self) }
private func errorText(_ error: Error) -> String { try! json(MCPErrorProjection(schemaVersion: QuotaQuery.schemaVersion, error: String(describing: error))) }
private struct MCPErrorProjection: Codable { let schemaVersion, error: String }
private struct MCPInputError: Error, CustomStringConvertible { let description: String; init(_ description: String) { self.description = description } }

private func object(_ value: [String: Value]?) throws -> [String: Value] { value ?? [:] }
private func rejectUnknown(_ arguments: [String: Value], allowed: Set<String>) throws {
    do { try QueryArguments.rejectUnknown(arguments.keys, allowed: allowed) }
    catch { throw MCPInputError("Unknown argument") }
}
private func requiredString(_ arguments: [String: Value], _ key: String) throws -> String {
    guard case .string(let value)? = arguments[key], !value.isEmpty else { throw MCPInputError("\(key) must be a non-empty string") }
    return value
}
private func optionalString(_ arguments: [String: Value], _ key: String) throws -> String? {
    guard let value = arguments[key] else { return nil }
    guard case .string(let string) = value, !string.isEmpty else { throw MCPInputError("\(key) must be a non-empty string") }
    return string
}
private func optionalBool(_ arguments: [String: Value], _ key: String) throws -> Bool? {
    guard let value = arguments[key] else { return nil }
    guard case .bool(let bool) = value else { throw MCPInputError("\(key) must be a boolean") }
    return bool
}
private func parseRange(_ raw: String) throws -> TimeInterval {
    guard let suffix = raw.last, suffix == "m" || suffix == "h", let amount = Double(raw.dropLast()), amount > 0 else { throw MCPInputError("range must use a positive m or h value") }
    return amount * (suffix == "h" ? 3600 : 60)
}

private extension JSONEncoder { static var sorted: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder } }
