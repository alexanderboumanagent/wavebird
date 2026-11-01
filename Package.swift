// swift-tools-version: 6.2
import PackageDescription

// The Xcode project remains the distribution build. This also lets contributors
// compile the app and run its byte-vector tests with Command Line Tools only.
let package = Package(
    name: "WaveBird",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "WaveBird", targets: ["WaveBird"])],
    dependencies: [
        // Xcode bundles Testing; Command Line Tools do not always include it.
        .package(url: "https://github.com/swiftlang/swift-testing.git", exact: "6.2.4"),
    ],
    targets: [
        .executableTarget(
            name: "WaveBird", path: "WaveBird",
            exclude: ["Assets.xcassets", "HID/Xbox.md", "WaveBird.entitlements"],
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
        .testTarget(
            name: "WaveBirdTests",
            dependencies: ["WaveBird", .product(name: "Testing", package: "swift-testing")],
            path: "WaveBirdTests"
        ),
    ]
)
