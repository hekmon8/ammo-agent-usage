// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ammo",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "QuotaProviders", targets: ["QuotaProviders"]),
        .library(name: "QuotaCollector", targets: ["QuotaCollector"]),
        .library(name: "QuotaIPC", targets: ["QuotaIPC"]),
        .library(name: "QuotaSync", targets: ["QuotaSync"]),
        .executable(name: "qi", targets: ["qi"]),
        .executable(name: "qi-mcp", targets: ["qi-mcp"]),
        .library(name: "QuotaCore", targets: ["QuotaCore"]),
        .library(name: "QuotaStore", targets: ["QuotaStore"]),
        .library(name: "QuotaDesign", targets: ["QuotaDesign"]),
        .library(name: "QuotaPhone", targets: ["QuotaPhone"]),
        .library(name: "QuotaWidgets", targets: ["QuotaWidgets"]),
        .executable(name: "AmmoMac", targets: ["AmmoMac"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")
    ],
    targets: [
        .testTarget(name: "AmmoMacTests", dependencies: ["AmmoMac", "QuotaCore", "QuotaDesign", "QuotaPhone"], path: "tests/macos"),
        .testTarget(name: "QuotaWidgetTests", dependencies: ["QuotaWidgets", "QuotaCore"], path: "tests/widgets"),
        .testTarget(name: "QuotaIPCTests", dependencies: ["QuotaIPC", "QuotaStore"], path: "tests/ipc"),
        .testTarget(name: "QuotaPhoneTests", dependencies: ["QuotaPhone"], path: "tests/ios"),
        .target(name: "QuotaQuery", dependencies: ["QuotaCore", "QuotaStore"], path: "packages/QuotaQuery/Sources/QuotaQuery", resources: [.process("Resources")]),
        .target(name: "QuotaMCP", dependencies: ["QuotaQuery", .product(name: "MCP", package: "swift-sdk")], path: "packages/QuotaQuery/Sources/QuotaMCP"),
        .executableTarget(name: "qi", dependencies: ["QuotaQuery", "QuotaMCP", "QuotaCore", "QuotaStore", "QuotaIPC"], path: "apps/cli/qi"),
        .executableTarget(name: "qi-mcp", dependencies: ["QuotaQuery", "QuotaMCP", "QuotaCore", "QuotaStore"], path: "apps/cli/qi-mcp"),
        .testTarget(name: "QuotaQueryTests", dependencies: ["QuotaQuery", "QuotaCore", "QuotaStore"], path: "tests/cli"),
        .target(name: "QuotaIPC", dependencies: ["QuotaStore"], path: "packages/QuotaIPC/Sources/QuotaIPC"),
        .target(name: "QuotaSync", dependencies: ["QuotaCore", "QuotaStore"], path: "packages/QuotaSync/Sources/QuotaSync"),
        .testTarget(name: "QuotaSyncTests", dependencies: ["QuotaCore", "QuotaSync", "QuotaStore"], path: "tests/sync"),
        .target(name: "QuotaCollector", dependencies: ["QuotaCore", "QuotaStore", "QuotaProviders"], path: "packages/QuotaCollector/Sources/QuotaCollector"),
        .testTarget(name: "QuotaCollectorTests", dependencies: ["QuotaCore", "QuotaStore", "QuotaProviders", "QuotaCollector", "CSQLite"], path: "tests/collector"),
        .target(name: "QuotaProviders", dependencies: ["QuotaCore"], path: "packages/QuotaProviders/Sources/QuotaProviders"),
        .testTarget(name: "QuotaProviderTests", dependencies: ["QuotaCore", "QuotaProviders"], path: "tests/providers"),
        .systemLibrary(name: "CSQLite", path: "packages/QuotaStore/Sources/CSQLite"),
        .target(name: "QuotaStore", dependencies: ["QuotaCore", "CSQLite"], path: "packages/QuotaStore/Sources/QuotaStore"),
        .testTarget(name: "QuotaStoreTests", dependencies: ["QuotaCore", "QuotaStore", "CSQLite"], path: "tests/store"),
        .target(name: "QuotaCore", path: "packages/QuotaCore/Sources/QuotaCore", resources: [.process("Resources")]),
        .target(name: "QuotaDesign", dependencies: ["QuotaCore"], path: "packages/QuotaDesign/Sources/QuotaDesign", resources: [.process("Resources")]),
        .target(name: "QuotaPhone", dependencies: ["QuotaCore", "QuotaDesign", "QuotaSync", "QuotaStore"], path: "apps/ios"),
        .target(name: "QuotaWidgets", dependencies: ["QuotaCore", "QuotaDesign", "QuotaSync"], path: "extensions/widgets"),
        .executableTarget(name: "AmmoMac", dependencies: ["QuotaPhone", "QuotaCore", "QuotaDesign", "QuotaStore", "QuotaProviders", "QuotaCollector", "QuotaIPC", "QuotaSync"], path: "apps/macos"),
        .testTarget(name: "QuotaCoreTests", dependencies: ["QuotaCore", "QuotaDesign"], path: "tests/contracts")
    ],
    swiftLanguageModes: [.v6]
)
