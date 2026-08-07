// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClawBar",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "ClawBar",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/ClawBar",
            // Swift 5 mode deliberately: the FSEvents C callback and NSStatusItem
            // plumbing fight strict concurrency for no real safety gain here. The code
            // is @MainActor-annotated throughout regardless.
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Sparkle.framework is copied into Contents/Frameworks by Scripts/build.sh,
            // so the executable needs to look there at runtime. SPM has no notion of an
            // .app bundle, hence the raw rpath.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        )
    ]
)
