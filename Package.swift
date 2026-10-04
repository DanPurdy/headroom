// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Headroom",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "headroom", targets: ["headroom"]),
        .executable(name: "HeadroomApp", targets: ["HeadroomApp"]),
    ],
    targets: [
        .target(name: "HeadroomCore"),
        .executableTarget(name: "headroom", dependencies: ["HeadroomCore"]),
        .executableTarget(name: "HeadroomApp", dependencies: ["HeadroomCore"]),
        .testTarget(name: "HeadroomCoreTests", dependencies: ["HeadroomCore"]),
    ],
    swiftLanguageModes: [.v5]
)
