// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TezNativePreview",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TezNativePreview", targets: ["TezNative"])
    ],
    targets: [
        .executableTarget(name: "TezNative", path: "Sources/TezNative")
    ]
)
