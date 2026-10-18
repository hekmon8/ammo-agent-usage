import Foundation

@main
struct RoundtripCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "Usage", code: 2, userInfo: [NSLocalizedDescriptionKey:"Pass contracts/fixtures directory"])
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in urls {
            let original = try Data(contentsOf: url)
            let value = try JSONDecoder().decode(Snapshot.self, from: original)
            let encoded = try JSONEncoder().encode(value)
            let lhs = try JSONSerialization.jsonObject(with: original) as! NSDictionary
            let rhs = try JSONSerialization.jsonObject(with: encoded) as! NSDictionary
            guard lhs.isEqual(to: rhs as! [AnyHashable: Any]) else {
                throw NSError(domain: "Roundtrip", code: 1, userInfo: [NSLocalizedDescriptionKey:url.lastPathComponent])
            }
        }
        print("PASS: Swift Codable roundtrip preserves all keys/nulls for \(urls.count) fixtures. DTO only; no Apple app compiled.")
    }
}
