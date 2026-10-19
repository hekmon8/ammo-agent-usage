import Foundation
import XCTest
@testable import qi

final class CommandTests: XCTestCase {
    private let syntheticDirectory = "/tmp/qi-command-parser-test"

    func testReadmeExamplesParseWithoutExecutingCommands() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let readme = try String(contentsOf: root.appendingPathComponent("apps/cli/README.md"), encoding: .utf8)
        // README examples use one-line, whitespace-separated arguments. Include
        // both fenced commands and inline examples, but not the qi-mcp binary.
        let pattern = try NSRegularExpression(pattern: #"\.build/debug/qi(?=\s)([^`\r\n]+)"#)
        let matches = pattern.matches(in: readme, range: NSRange(readme.startIndex..., in: readme))
        XCTAssertFalse(matches.isEmpty, "The CLI README must contain executable examples")
        var doctorExamples = 0
        for match in matches {
            let range = try XCTUnwrap(Range(match.range(at: 1), in: readme))
            let arguments = readme[range].split(whereSeparator: \.isWhitespace).map(String.init)
            // Parse only: no command handler, snapshot, IPC, or credentials are read.
            let command = try Command(arguments: arguments + ["--data-dir", syntheticDirectory])
            XCTAssertEqual(command.directory.path, syntheticDirectory)
            if case .doctor = command.action { doctorExamples += 1 }
        }
        XCTAssertGreaterThan(doctorExamples, 0, "Keep a working doctor example in the CLI README")
    }

    func testDoctorAcceptsRedactionAndGlobalOptions() throws {
        let examples = [
            ["doctor", "--redact"],
            ["--json", "doctor", "--redact"],
            ["doctor", "--json", "--redact", "--require-fresh"],
            ["--require-fresh", "doctor", "--redact", "--json"]
        ]
        for arguments in examples {
            for isolated in [
                ["--data-dir", syntheticDirectory] + arguments,
                arguments + ["--data-dir", syntheticDirectory]
            ] {
                let command = try Command(arguments: isolated)
                guard case .doctor = command.action else {
                    return XCTFail("Expected doctor action for \(arguments)")
                }
                XCTAssertEqual(command.directory.path, syntheticDirectory)
                XCTAssertEqual(command.requireFresh, arguments.contains("--require-fresh"))
            }
        }
    }

    func testDoctorRejectsMissingRedactionAndUnexpectedArguments() {
        let examples = [
            ["doctor"],
            ["doctor", "--json"],
            ["doctor", "--require-fresh"],
            ["doctor", "--redact", "--redact"],
            ["doctor", "--redact", "--unknown"],
            ["doctor", "--redact", "extra"]
        ]
        for arguments in examples {
            XCTAssertThrowsError(try Command(arguments: arguments + ["--data-dir", syntheticDirectory])) {
                XCTAssertEqual(($0 as? CommandError)?.exitCode, 2)
            }
        }
    }
}
