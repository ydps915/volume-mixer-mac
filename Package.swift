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
            // No SPM `resources:` on purpose. The generated `Bundle.module`
            // accessor falls back to an absolute build-directory path and traps
            // when it is missing, so the menu-bar icon is staged into the app
            // bundle by `script/build_and_run.sh` and read from `Bundle.main`.
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "VolumeMixerTests",
            dependencies: ["VolumeMixer"],
            path: "Tests/VolumeMixerTests"
        ),
    ]
)
