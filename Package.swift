// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WLCore",
    platforms: [.macOS(.v13), .iOS("26.0")],
    products: [.library(name: "WLCore", targets: ["WLCore"])],
    targets: [.target(name: "WLCore"), .testTarget(name: "WLCoreTests", dependencies: ["WLCore"])],
    swiftLanguageModes: [.v5]
)
