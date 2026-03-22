// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "quick-eye",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "quick-eye", targets: ["QuickEyeApp"]),
    ],
    targets: [
        .executableTarget(
            name: "QuickEyeApp"
        ),
    ]
)
