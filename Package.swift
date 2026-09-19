// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MoReadCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "MoReadCore", targets: ["MoReadCore"])],
    dependencies: [.package(url: "https://github.com/readium/ZIPFoundation.git", from: "3.0.1")],
    targets: [
        .target(name: "MoReadCore", dependencies: [.product(name: "ReadiumZIPFoundation", package: "ZIPFoundation")], resources: [.process("Resources")]),
        .testTarget(name: "MoReadCoreTests", dependencies: ["MoReadCore"])
    ]
)
