// swift-tools-version: 5.9
// Swift package for Flutter builds with Swift Package Manager.
// CocoaPods builds use ../anchored_health_native.podspec with the same sources.

import PackageDescription

let package = Package(
    name: "anchored_health_native",
    platforms: [
        .iOS("15.0")
    ],
    products: [
        .library(name: "anchored-health-native", targets: ["anchored_health_native"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "anchored_health_native",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ],
            linkerSettings: [
                .linkedFramework("HealthKit")
            ]
        )
    ]
)
