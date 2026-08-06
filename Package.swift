// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClawBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClawBar",
            path: "Sources/ClawBar",
            // Swift 5 mode deliberately: the FSEvents C callback and NSStatusItem
            // plumbing fight strict concurrency for no real safety gain here. The code
            // is @MainActor-annotated throughout regardless.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
