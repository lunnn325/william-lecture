// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WLCore",
    platforms: [.macOS(.v13), .iOS("26.0")],
    products: [.library(name: "WLCore", targets: ["WLCore"]), .library(name: "WLAppleAudio", targets: ["WLAppleAudio"])],
    targets: [.target(name: "WLCore"), .target(name: "WLAppleAudio"),
        .testTarget(name: "WLCoreTests", dependencies: ["WLCore"]),
        .testTarget(name: "WLAppleAudioTests", dependencies: ["WLAppleAudio"])],
    swiftLanguageModes: [.v5]
)
