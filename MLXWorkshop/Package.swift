// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MLXWorkshop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MLXWorkshop", targets: ["MLXWorkshopApp"])
    ],
    targets: [
        .executableTarget(
            name: "MLXWorkshopApp",
            path: "Sources/MLXWorkshopApp"
        ),
        .testTarget(
            name: "MLXWorkshopAppTests",
            dependencies: ["MLXWorkshopApp"],
            path: "Tests/MLXWorkshopAppTests"
        )
    ]
)
