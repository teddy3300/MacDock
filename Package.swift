// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacDock",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacDock",
            path: "Sources/MacDock"
        ),
    ]
)
