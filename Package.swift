// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "apple-calendar",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Pinned exactly: the HTTP transport's session semantics are what this server is built
        // around, so an SDK bump is a deliberate change, not a side effect of resolution.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        // Used directly by HTTPTransport.swift; declared explicitly rather than relying on
        // them being transitive deps of Hummingbird/swift-sdk.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
        // HTTPRunner builds its own ServiceGroup so sessions can be drained before the
        // server stops; Hummingbird's runService() gives no hook that runs first.
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.11.0"),
    ],
    targets: [
        .executableTarget(
            name: "apple-calendar",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "UnixSignals", package: "swift-service-lifecycle"),
            ],
            path: "Sources/AppleCalendar"
        ),
        .testTarget(
            name: "AppleCalendarTests",
            dependencies: [
                "apple-calendar",
                .product(name: "MCP", package: "swift-sdk"),
                // HTTPTransportStressTests reads the bound port off the NIO Channel and
                // drives the ServiceGroup's graceful shutdown.
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "Tests/AppleCalendarTests"
        ),
    ]
)
