// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GeoSleuth",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GeoSleuth",
            path: "Sources/GeoSleuth"
        )
    ]
)
