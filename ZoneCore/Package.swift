// swift-tools-version: 5.9
// by zayd/cold @ zayd.wtf
import PackageDescription

let package = Package(
    name: "ZoneCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ZoneCore", targets: ["ZoneCore"]),
    ],
    targets: [
        .target(
            name: "ZoneCore",
            path: "Sources/ZoneCore",
            resources: [.copy("Resources/en-words.txt"),
                        .copy("Resources/modern-words.txt"), .copy("Resources/more-words.txt"), .copy("Resources/chat-ranks.txt"), .copy("Resources/emoji.tsv"), .copy("Resources/emoji-search.tsv"), .copy("Resources/futoswipe.bin"), .copy("Resources/SwipeNotices.txt")],
            // The keyboard runs spelling on every keystroke; at -Onone it is about 50 times slower
            // and the phone lags, so Debug builds are optimized too. Local packages may use this flag.
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .testTarget(
            name: "ZoneCoreTests",
            dependencies: ["ZoneCore"],
            path: "Tests/ZoneCoreTests",
            resources: [.copy("Fixtures/futo-swipe-fixture.txt"), .copy("Fixtures/quiet-meter-traces.txt")]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
