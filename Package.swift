// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Defrost",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Defrost",
            path: "Sources/Defrost",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("ServiceManagement")]
        ),
    ]
)
