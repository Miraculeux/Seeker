// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Seeker",
    platforms: [.macOS(.v26)],
    targets: [
        // C target wrapping the official xxHash single-header library.
        // Used by the duplicate-file finder to compute fast non-cryptographic
        // digests of file contents at near-memory-bandwidth speeds.
        .target(
            name: "CXXHash",
            path: "Seeker/Sources/CXXHash",
            sources: ["xxhash.c"],
            publicHeadersPath: "include",
            cSettings: [
                .define("XXH_STATIC_LINKING_ONLY"),
                // Release builds want aggressive vectorisation; xxHash is
                // pure scalar/SIMD C with no UB and benefits substantially.
                .unsafeFlags(["-O3"], .when(configuration: .release))
            ]
        ),
        .executableTarget(
            name: "Seeker",
            dependencies: ["CXXHash"],
            path: "Seeker/Sources",
            exclude: [
                "Info.plist",
                "CXXHash"
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
