import Foundation
import QuotaIPC
import QuotaMCP
import QuotaQuery

@main
struct QiCommand {
    static func main() async {
        do {
            let command = try Command(arguments: Array(CommandLine.arguments.dropFirst()))
            let query = QuotaQuery(directory: command.directory)
            switch command.action {
            case .status:
                try printJSON(query.status(requireFresh: command.requireFresh))
            case .list(let provider, let includeStale):
                try printJSON(query.list(providerId: provider, includeStale: includeStale, requireFresh: command.requireFresh))
            case .get(let id):
                try printJSON(query.get(windowId: id, requireFresh: command.requireFresh))
            case .history(let id, let range):
                try printJSON(query.history(windowId: id, range: range, requireFresh: command.requireFresh))
            case .doctor:
                try printJSON(query.health())
            case .refresh(let provider, let timeout):
                try await RefreshClient.request(directory: command.directory, provider: provider, timeout: timeout)
                try printJSON(RefreshResult(schemaVersion: QuotaQuery.schemaVersion, result: "refresh_requested"))
            case .mcp:
                try await QuotaMCPServer(directory: command.directory).run()
            }
        } catch let error as CommandError {
            fail(error.description, code: error.exitCode)
        } catch let error as QueryError {
            let code: Int32 = error == .unavailable ? 3 : (error == .noFreshData ? 4 : 2)
            fail(error.description, code: code)
        } catch let error as IPCError {
            let code: Int32
            switch error {
            case .unavailable: code = 3
            case .permission: code = 5
            case .timeout, .failed: code = 6
            case .invalid: code = 2
            }
            fail("Refresh failed: \(error)", code: code)
        } catch {
            fail("\(error)", code: 6)
        }
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        Foundation.exit(code)
    }
}

private struct RefreshResult: Codable { let schemaVersion, result: String }

struct Command {
    enum Action { case status, list(String?, Bool), get(String), history(String, TimeInterval), doctor, refresh(String?, TimeInterval), mcp }
    let directory: URL
    let requireFresh: Bool
    let action: Action

    init(arguments: [String]) throws {
        var args = arguments
        var directory = QuotaQuery.defaultDirectory
        var requireFresh = false
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--data-dir":
                guard index + 1 < args.count, !args[index + 1].hasPrefix("-") else { throw CommandError("--data-dir requires a directory", 2) }
                directory = URL(fileURLWithPath: args[index + 1], isDirectory: true)
                args.removeSubrange(index...(index + 1))
            case "--require-fresh": requireFresh = true; args.remove(at: index)
            case "--json": args.remove(at: index)
            default: index += 1
            }
        }
        guard let verb = args.first else { throw CommandError("Expected a command", 2) }
        args.removeFirst()
        switch verb {
        case "status":
            guard args.isEmpty else { throw CommandError("status takes no arguments", 2) }; action = .status
        case "quota":
            guard let operation = args.first else { throw CommandError("Expected quota list or quota get", 2) }
            args.removeFirst()
            if operation == "list" {
                var provider: String?; var includeStale = true
                while let flag = args.first {
                    switch flag {
                    case "--provider": args.removeFirst(); guard let id = args.first, !id.hasPrefix("-") else { throw CommandError("--provider requires an id", 2) }; provider = args.removeFirst()
                    case "--include-stale": args.removeFirst(); includeStale = true
                    case "--exclude-stale": args.removeFirst(); includeStale = false
                    default: throw CommandError("Unknown argument: \(flag)", 2)
                    }
                }
                action = .list(provider, includeStale)
            } else if operation == "get" {
                guard args.count == 2, args[0] == "--window", !args[1].hasPrefix("-") else { throw CommandError("quota get requires --window <id>", 2) }
                action = .get(args[1])
            } else { throw CommandError("Expected quota list or quota get", 2) }
        case "history":
            guard args.count == 4, args[0] == "--window", args[2] == "--range" else { throw CommandError("history requires --window <id> --range <number><m|h>", 2) }
            action = .history(args[1], try Self.parseRange(args[3]))
        case "doctor":
            guard args == ["--redact"] else { throw CommandError("doctor requires --redact", 2) }; action = .doctor
        case "refresh":
            var provider: String?; var timeout: TimeInterval = 15; var wait = false
            while let flag = args.first {
                switch flag {
                case "--provider": args.removeFirst(); guard let id = args.first, !id.hasPrefix("-") else { throw CommandError("--provider requires an id", 2) }; provider = args.removeFirst()
                case "--wait": args.removeFirst(); wait = true
                case "--timeout": args.removeFirst(); guard let raw = args.first, let seconds = Double(raw), seconds > 0, seconds <= 60 else { throw CommandError("--timeout must be between 0 and 60 seconds", 2) }; args.removeFirst(); timeout = seconds
                default: throw CommandError("Unknown argument: \(flag)", 2)
                }
            }
            guard wait else { throw CommandError("refresh requires --wait; background collection is not started by qi", 2) }
            action = .refresh(provider, timeout)
        case "mcp":
            guard args == ["serve", "--stdio"] else { throw CommandError("Expected mcp serve --stdio", 2) }; action = .mcp
        default: throw CommandError("Unknown command: \(verb)", 2)
        }
        self.directory = directory; self.requireFresh = requireFresh
    }

    private static func parseRange(_ raw: String) throws -> TimeInterval {
        guard let suffix = raw.last, suffix == "m" || suffix == "h", let amount = Double(raw.dropLast()), amount > 0 else { throw CommandError("range must use a positive m or h value", 2) }
        return amount * (suffix == "h" ? 3600 : 60)
    }
}

struct CommandError: Error, CustomStringConvertible { let description: String; let exitCode: Int32; init(_ description: String, _ exitCode: Int32) { self.description = description; self.exitCode = exitCode } }
