// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ScholarBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ScholarBar",
            path: "Sources/ScholarBar"
        )
    ]
)
