// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "apple-calendar",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.9.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        // Used directly by HTTPTransport.swift; declared explicitly rather than relying on
        // them being transitive deps of Hummingbird/swift-sdk.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "apple-calendar",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            path: "Sources/AppleCalendar"
        ),
        .testTarget(
            name: "AppleCalendarTests",
            dependencies: ["apple-calendar"],
            path: "Tests/AppleCalendarTests"
        ),
    ]
)
