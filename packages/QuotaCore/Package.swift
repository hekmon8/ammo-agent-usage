// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "QuotaCore", platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "QuotaCore", targets: ["QuotaCore"])],
    targets: [.target(name: "QuotaCore", resources: [.process("Resources")])], swiftLanguageModes: [.v6])
