// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "ReadBudMac",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ReadBudMac", targets: ["ReadBudMac"])
    ],
    dependencies: [
        .package(url: "https://github.com/Jud/kokoro-coreml.git", from: "0.11.0")
    ],
    targets: [
        .executableTarget(
            name: "ReadBudMac",
            dependencies: [
                .product(name: "KokoroCoreML", package: "kokoro-coreml")
            ],
            path: "Sources/ReadBudMac",
            resources: [
                .copy("Resources")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Support/Info.plist"
                ])
            ]
        ),
        .testTarget(name: "ReadBudMacTests", dependencies: ["ReadBudMac"])
    ]
)
