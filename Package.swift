// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Seeker",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Seeker",
            path: "Seeker/Sources",
            exclude: ["Info.plist"],
            resources: [
                .process("../Assets.xcassets"),
                .copy("../Resources/AppIcon.icns")
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
