// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "rec",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "rec", targets: ["rec"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "CBridge",
            dependencies: [],
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "rec",
            dependencies: ["CBridge"]
        )
    ]
)
