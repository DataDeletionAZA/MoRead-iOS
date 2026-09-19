// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MoReadCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "MoReadCore", targets: ["MoReadCore"])],
    targets: [
        .target(name: "MoReadCore", resources: [.process("Resources")]),
        .testTarget(name: "MoReadCoreTests", dependencies: ["MoReadCore"])
    ]
)
