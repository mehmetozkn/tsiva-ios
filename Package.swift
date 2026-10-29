// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tsiva",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(name: "Tsiva", targets: ["Tsiva"])
    ],
    targets: [
        .target(name: "TsivaCrashHandler"),
        .target(
            name: "Tsiva",
            dependencies: ["TsivaCrashHandler"],
            resources: [.copy("Resources/PrivacyInfo.xcprivacy")]
        ),
        .testTarget(name: "TsivaTests", dependencies: ["Tsiva"])
    ]
)
