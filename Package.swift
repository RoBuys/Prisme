// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Prisme",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Prisme", path: "Sources/Prisme"),
        .testTarget(name: "PrismeTests", dependencies: ["Prisme"], path: "Tests/PrismeTests",
                    resources: [.copy("Fixtures")]),
    ]
)
