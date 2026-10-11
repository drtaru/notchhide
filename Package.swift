// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchHide",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "NotchHide", path: "Sources/NotchHide")
    ]
)
