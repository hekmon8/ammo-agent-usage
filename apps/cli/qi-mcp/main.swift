import Foundation
import QuotaMCP
import QuotaQuery

@main
struct QiMCPCommand {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            var directory = QuotaQuery.defaultDirectory
            if args.count == 2, args[0] == "--data-dir" { directory = URL(fileURLWithPath: args[1], isDirectory: true) }
            else if !args.isEmpty { throw MCPCLIError("Usage: qi-mcp [--data-dir <directory>]") }
            try await QuotaMCPServer(directory: directory).run()
        } catch {
            FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8))
            Foundation.exit(2)
        }
    }
}
private struct MCPCLIError: Error, CustomStringConvertible { let description: String; init(_ description: String) { self.description = description } }
