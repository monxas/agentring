// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "AgentRingCore", platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "AgentRingCore", targets: ["AgentRingCore"])],
    targets: [.target(name: "AgentRingCore"), .testTarget(name: "AgentRingCoreTests", dependencies: ["AgentRingCore"])])
