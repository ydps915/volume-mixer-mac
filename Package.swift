// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VolumeMixer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VolumeMixer", targets: ["VolumeMixer"]),
    ],
    targets: [
        .target(
            name: "AtomicGain",
            path: "Sources/AtomicGain",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "VolumeMixer",
            dependencies: ["AtomicGain"],
            path: "Sources/VolumeMixer",
            resources: [
                .copy("Resources/MenuBarIcon.png"),
            ]
        ),
        .testTarget(
            name: "VolumeMixerTests",
            dependencies: ["VolumeMixer"],
            path: "Tests/VolumeMixerTests"
        ),
    ]
)
