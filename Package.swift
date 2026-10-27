// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CrossAgent",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "CrossAgent",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/CrossAgent",
            resources: [.copy("Resources/AppIcon.icns")]
        ),
        .testTarget(
            name: "CrossAgentTests",
            dependencies: ["CrossAgent"],
            path: "Tests/CrossAgentTests"
        ),
    ]
)
