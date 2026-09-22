// swift-tools-version: 5.9
import PackageDescription

// A small test harness for the actual configuration sources; the app builds in Xcode.
let package = Package(
    name: "SwipeAeroSpaceConfiguration",
    platforms: [.macOS(.v13)],
    dependencies: [.package(url: "https://github.com/LebJe/TOMLKit.git", .upToNextMinor(from: "0.5.0"))],
    targets: [
        .target(
            name: "ConfigurationSupport",
            dependencies: [.product(name: "TOMLKit", package: "TOMLKit")],
            path: "SwipeAeroSpace",
            exclude: [
                "AboutView.swift", "Assets.xcassets", "BundleInfo.swift", "LaunchAtLogin.swift",
                "Preview Content", "PrivacyHelper.swift", "SettingsView.swift",
                "SwipeAeroSpace.entitlements", "SwipeAeroSpaceApp.swift", "SwipeManager.swift",
                "WorkspaceOverlayView.swift",
            ],
            sources: ["Configuration.swift", "ConfigStorage.swift"]
        ),
        .testTarget(name: "ConfigurationTests", dependencies: ["ConfigurationSupport"],
                    path: "Tests/ConfigurationTests"),
    ]
)
