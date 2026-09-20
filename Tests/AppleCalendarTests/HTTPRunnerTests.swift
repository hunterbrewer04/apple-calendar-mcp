import XCTest
import NIOCore
@testable import apple_calendar

/// Exercises the bind-retry policy with a fake clock sleep; no sockets are opened.
final class HTTPRunnerTests: XCTestCase {
    func testRetriesAddrNotAvailUntilBindSucceeds() async throws {
        var attempts = 0
        var sleeps: [Duration] = []
        try await HTTPRunner.withBindRetry(sleep: { sleeps.append($0) }) {
            attempts += 1
            if attempts < 3 { throw IOError(errnoCode: EADDRNOTAVAIL, reason: "x") }
        }
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(sleeps, [.seconds(2), .seconds(2)])
    }

    func testRetriesUnresolvableHostToo() async throws {
        // NIO's `UnknownHost` has a package-scoped init, so resolve a reserved `.invalid` name
        // (RFC 6761: resolvers answer NXDOMAIN without asking the network) to get a real one.
        var attempts = 0
        var sleeps: [Duration] = []
        try await HTTPRunner.withBindRetry(sleep: { sleeps.append($0) }) {
            attempts += 1
            if attempts < 2 { _ = try SocketAddress.makeAddressResolvingHost("mac.nonexistent.invalid", port: 3456) }
        }
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(sleeps, [.seconds(2)])
    }

    func testOtherBindErrorsPropagateOnFirstAttempt() async {
        var attempts = 0
        var sleeps: [Duration] = []
        do {
            try await HTTPRunner.withBindRetry(sleep: { sleeps.append($0) }) {
                attempts += 1
                throw IOError(errnoCode: EADDRINUSE, reason: "x")
            }
            XCTFail("EADDRINUSE should have propagated")
        } catch {
            XCTAssertEqual((error as? IOError)?.errnoCode, EADDRINUSE)
        }
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(sleeps.isEmpty)
    }

    func testAddrNotAvailPropagatesOnceTheWindowCloses() async {
        var sleeps: [Duration] = []
        do {
            try await HTTPRunner.withBindRetry(timeout: .zero, sleep: { sleeps.append($0) }) {
                throw IOError(errnoCode: EADDRNOTAVAIL, reason: "x")
            }
            XCTFail("EADDRNOTAVAIL should propagate once the deadline has passed")
        } catch {
            XCTAssertEqual((error as? IOError)?.errnoCode, EADDRNOTAVAIL)
        }
        XCTAssertTrue(sleeps.isEmpty)
    }
}
