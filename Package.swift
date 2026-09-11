// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Qv2ray-mac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Qv2rayMac",
            path: "Sources/Qv2rayMac"
        )
    ]
)
