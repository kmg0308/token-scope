// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokenMeter",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "TokenMeter", targets: ["TokenMeter"]),
        .executable(name: "TokenMeterSelfTest", targets: ["TokenMeterSelfTest"]),
        .library(name: "TokenMeterCore", targets: ["TokenMeterCore"])
    ],
    targets: [
        .target(
            name: "TokenMeterCore",
            path: "Sources/TokenMeterCore"
        ),
        .executableTarget(
            name: "TokenMeter",
            dependencies: ["TokenMeterCore"],
            path: "Sources/TokenMeter"
        ),
        .executableTarget(
            name: "TokenMeterSelfTest",
            dependencies: ["TokenMeterSelfTestSupport"],
            path: "Sources/TokenMeterSelfTest"
        ),
        .target(
            name: "TokenMeterSelfTestSupport",
            dependencies: ["TokenMeterCore"],
            path: "Sources/TokenMeterSelfTestSupport"
        )
    ]
)
