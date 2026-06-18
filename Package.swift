// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MonitorAgent",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.4.1"),
    ],
    targets: [
        .executableTarget(
            name: "MonitorAgent",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/MonitorAgent"
        ),
    ]
)
