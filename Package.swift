// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hangar",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "HangarCore", resources: [.process("Localizable.xcstrings")]),
        .executableTarget(name: "Hangar", dependencies: ["HangarCore"], resources: [.process("Localizable.xcstrings")]),
        .testTarget(name: "HangarCoreTests", dependencies: ["HangarCore"]),
    ]
)
