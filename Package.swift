// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MoReadCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "MoReadCore", targets: ["MoReadCore"])],
    dependencies: [.package(url: "https://github.com/readium/ZIPFoundation.git", from: "3.0.1"),
                   .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.13.9")],
    targets: [
        .target(name: "MoReadCore", dependencies: [.product(name: "ReadiumZIPFoundation", package: "ZIPFoundation"), "SwiftSoup"], resources: [.process("Resources/txtTocRule.json"), .copy("Resources/ChineseConversion")]),
        .testTarget(name: "MoReadCoreTests", dependencies: ["MoReadCore"], resources: [.copy("Resources/Dictionary"), .copy("Resources/ChineseConversion.json")])
    ]
)
