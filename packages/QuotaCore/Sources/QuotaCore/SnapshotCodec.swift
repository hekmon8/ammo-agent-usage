import Foundation
import CoreFoundation

public struct ContractError: Error, CustomStringConvertible {
    public let description: String
    init(_ message: String) { description = message }
}

/// Strict validation of the bundled v1 schema subset before Codable can discard keys.
public enum SnapshotCodec {
    /// Budget shared by every reader and collector; see the design doc
    /// "每快照上限" line. The JSON schema's `windows.maxItems` must match maxWindows.
    public static let maxBytes = 131_072
    public static let maxWindows = 80

    public static func decode(_ data: Data) throws -> Snapshot {
        guard data.count <= maxBytes else { throw ContractError("Snapshot exceeds 128 KiB") }
        let object = try JSONSerialization.jsonObject(with: data)
        let schema = try JSONSerialization.jsonObject(with: Data(contentsOf:
            Bundle.module.url(forResource: "snapshot.schema", withExtension: "json")!)) as! [String: Any]
        try validate(object, schema: schema, root: schema)
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        guard Set(snapshot.windows.map(\.id)).count == snapshot.windows.count,
              Set(snapshot.windows.map { "\($0.providerId)/\($0.accountId)/\($0.quotaKey)" }).count == snapshot.windows.count
        else { throw ContractError("Duplicate window identity") }
        for q in snapshot.windows {
            if let observed = q.observedAt.flatMap(QuotaRules.date), let stale = q.staleAt.flatMap(QuotaRules.date), stale < observed {
                throw ContractError("staleAt precedes observation")
            }
            if q.window.kind == .fixed, let start = q.window.startsAt.flatMap(QuotaRules.date),
               let end = q.window.resetsAt.flatMap(QuotaRules.date), let duration = q.window.durationSeconds,
               abs(end.timeIntervalSince(start) - Double(duration)) > 0.001 {
                throw ContractError("Fixed window duration mismatch")
            }
        }
        return snapshot
    }

    public static func encode(_ snapshot: Snapshot) throws -> Data {
        let data = try JSONEncoder().encode(snapshot)
        _ = try decode(data)
        return data
    }

    private static func validate(_ value: Any, schema s: [String: Any], root: [String: Any]) throws {
        func require(_ condition: Bool, _ reason: String) throws {
            if !condition { throw ContractError(reason) }
        }
        if let ref = s["$ref"] as? String {
            var node: Any = root
            for key in ref.dropFirst(2).split(separator: "/") { node = (node as! [String: Any])[String(key)]! }
            try validate(value, schema: node as! [String: Any], root: root)
        }
        if let branches = s["allOf"] as? [[String: Any]] {
            for branch in branches { try validate(value, schema: branch, root: root) }
        }
        if let branches = s["anyOf"] as? [[String: Any]] {
            try require(branches.contains { (try? validate(value, schema: $0, root: root)) != nil }, "No matching schema branch")
        }
        if let condition = s["if"] as? [String: Any] {
            let branch = (try? validate(value, schema: condition, root: root)) != nil ? "then" : "else"
            if let child = s[branch] as? [String: Any] { try validate(value, schema: child, root: root) }
        }
        let isNull = value is NSNull
        let number = value as? NSNumber
        let isNumber = number != nil && CFGetTypeID(number!) != CFBooleanGetTypeID()
        if let type = s["type"] {
            let types = (type as? [String]) ?? [type as! String]
            try require(types.contains { t in
                switch t {
                case "null": return isNull
                case "object": return value is [String: Any]
                case "array": return value is [Any]
                case "string": return value is String
                case "integer": return isNumber && number!.doubleValue.isFinite && number!.doubleValue.rounded() == number!.doubleValue
                default: return false
                }
            }, "Invalid JSON type")
        }
        if let constant = s["const"] { try require((value as AnyObject).isEqual(constant), "Unsupported schema version") }
        if let options = s["enum"] as? [String] { try require(options.contains(value as? String ?? ""), "Invalid enum") }
        if isNumber {
            if let min = s["minimum"] as? Double { try require(number!.doubleValue >= min, "Below minimum") }
            if let max = s["maximum"] as? Double { try require(number!.doubleValue <= max, "Above maximum") }
        }
        if let text = value as? String {
            if let min = s["minLength"] as? Int { try require(text.unicodeScalars.count >= min, "String too short") }
            if let max = s["maxLength"] as? Int { try require(text.unicodeScalars.count <= max, "String too long") }
            if let pattern = s["pattern"] as? String { try require(text.range(of: pattern, options: .regularExpression) != nil, "Invalid string format") }
            if s["format"] as? String == "date-time" { try require(QuotaRules.date(text) != nil, "Invalid timestamp") }
        }
        if let array = value as? [Any] {
            if let max = s["maxItems"] as? Int { try require(array.count <= max, "Too many items") }
            if let item = s["items"] as? [String: Any] { for v in array { try validate(v, schema: item, root: root) } }
        }
        if let object = value as? [String: Any] {
            let properties = s["properties"] as? [String: [String: Any]] ?? [:]
            for key in s["required"] as? [String] ?? [] { try require(object[key] != nil, "Missing required key: \(key)") }
            if s["additionalProperties"] as? Bool == false { try require(Set(object.keys).isSubset(of: Set(properties.keys)), "Unknown field") }
            for (key, v) in object { if let child = properties[key] { try validate(v, schema: child, root: root) } }
        }
    }
}
