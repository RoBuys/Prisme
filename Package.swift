// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Prisme",
    platforms: [.macOS(.v14)],
    targets: [
        // Microsoft's Xpress9 decoder (MIT), used to read the data model of .pbix files.
        .target(name: "CXpress9", path: "Sources/CXpress9", exclude: ["LICENSE"],
                cSettings: [.unsafeFlags(["-w"])]),
        .executableTarget(name: "Prisme", dependencies: ["CXpress9"], path: "Sources/Prisme"),
        .testTarget(name: "PrismeTests", dependencies: ["Prisme"], path: "Tests/PrismeTests",
                    resources: [.copy("Fixtures")]),
    ]
)
