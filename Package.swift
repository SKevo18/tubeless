// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tubeless",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Tubeless",
            path: "Sources/Tubeless"
        )
    ]
)
