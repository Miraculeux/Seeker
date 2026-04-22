// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Seeker",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Seeker",
            path: "Seeker/Sources",
            exclude: [
                "Info.plist"
            ],
            resources: [
                .process("../Assets.xcassets"),
                .copy("../Resources/AppIcon.icns")
            ],
            swiftSettings: [
                // Cross-module optimization lets the optimizer inline
                // across module boundaries in release builds. Negligible
                // effect for a single-module app today, but future-proofs
                // when sources get split into libraries.
                .unsafeFlags(["-cross-module-optimization"], .when(configuration: .release))
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Seeker/Sources/Info.plist"
                ])
            ]
        )
    ]
)
