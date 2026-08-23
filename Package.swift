// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "iLabelStudio",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "iLabelStudio", targets: ["iLabelMac"])
    ],
    targets: [
        .executableTarget(
            name: "iLabelMac",
            path: "Sources/iLabelMac"
        ),
        .testTarget(
            name: "iLabelMacTests",
            dependencies: ["iLabelMac"],
            path: "Tests/iLabelMacTests"
        )
    ]
)
