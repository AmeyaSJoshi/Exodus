import XCTest
@testable import EgressMapper

/// The deadline is what keeps an unreachable backend from spinning forever, so
/// it is worth proving it actually fires rather than trusting the code shape.
@MainActor
final class WithTimeoutTests: XCTestCase {
    func testOperationOutlastingTheLimitThrowsAndDoesNotWaitForIt() async throws {
        let limit = 1.0
        let start = Date()
        do {
            try await withTimeout(seconds: limit) {
                // Far longer than the limit: if the deadline did not fire, this
                // test would take a minute instead of a second.
                try await Task.sleep(for: .seconds(60))
            }
            XCTFail("Expected BackendTimeout")
        } catch is BackendTimeout {
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, limit + 2, "Timed out but only after \(elapsed)s")
        }
    }

    func testOperationFinishingUnderTheLimitReturnsItsValue() async throws {
        let value = try await withTimeout(seconds: 5) { () -> String in
            try await Task.sleep(for: .milliseconds(50))
            return "signed in"
        }
        XCTAssertEqual(value, "signed in")
    }

    func testOperationErrorPropagatesRatherThanReadingAsATimeout() async {
        struct Refused: Error {}
        do {
            try await withTimeout(seconds: 5) { throw Refused() }
            XCTFail("Expected Refused")
        } catch is BackendTimeout {
            XCTFail("A real failure was reported as a timeout")
        } catch is Refused {
            // Expected: bad credentials must not read as an unreachable server.
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }
}
