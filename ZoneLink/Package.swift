// swift-tools-version: 5.9
// by zayd/cold @ zayd.wtf
import PackageDescription

// Zone Link's transport: an iroh session between the phone and a paired computer.
//
// Only the Zone app links this. The keyboard, Messages, Watch and activity extensions never do:
// iroh adds megabytes, and the keyboard has a tight memory ceiling.
//
// `Vendor/` is not checked in. `scripts/fetch-iroh.sh` fills it with Zone's own build of
// iroh-ffi (`scripts/build-iroh.sh`, every revision pinned), and `xcodegen generate` runs that
// script. Both scripts say why the official prebuilt package is not used.
let package = Package(
    name: "ZoneLink",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "ZoneLink", targets: ["ZoneLink"]),
    ],
    dependencies: [
        .package(path: "../ZoneCore"),
    ],
    targets: [
        .binaryTarget(name: "Iroh", path: "Vendor/Iroh.xcframework"),
        // The generated Swift binding of iroh-ffi, unedited.
        .target(
            name: "IrohLib",
            dependencies: ["Iroh"],
            path: "Vendor/IrohLib",
            swiftSettings: [.unsafeFlags(["-suppress-warnings"])],
            linkerSettings: [
                // The Mac library reads the system's network settings through SystemConfiguration.
                // The iOS library must not (those functions are unavailable on iOS), so iOS does
                // not link it at all, and reads DNS servers through libresolv instead.
                .linkedFramework("SystemConfiguration", .when(platforms: [.macOS])),
                .linkedLibrary("resolv"),
                .linkedFramework("Network"),
                .linkedFramework("CoreWLAN", .when(platforms: [.macOS])),
            ]
        ),
        .target(
            name: "ZoneLink",
            dependencies: ["IrohLib", .product(name: "ZoneCore", package: "ZoneCore")],
            path: "Sources/ZoneLink"
        ),
        .testTarget(
            name: "ZoneLinkTests",
            dependencies: ["ZoneLink", .product(name: "ZoneCore", package: "ZoneCore")],
            path: "Tests/ZoneLinkTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
