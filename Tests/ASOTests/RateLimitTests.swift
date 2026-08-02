import XCTest
import Foundation
@testable import ASOCore

final class AppleRateLimitParsingTests: XCTestCase {

    /// The shape App Store Connect actually returns.
    func testParsesDocumentedHeaderShape() throws {
        let limit = try XCTUnwrap(
            AppleRateLimit(header: "user-hour-lim:7200;user-hour-rem:7183;"))
        XCTAssertEqual(limit.limit, 7200)
        XCTAssertEqual(limit.remaining, 7183)
    }

    func testToleratesWhitespaceAndMissingTrailingSemicolon() throws {
        let limit = try XCTUnwrap(
            AppleRateLimit(header: " user-hour-lim:3600 ; user-hour-rem:12 "))
        XCTAssertEqual(limit.limit, 3600)
        XCTAssertEqual(limit.remaining, 12)
    }

    /// Apple documents further keys and may add more; unknown ones must not
    /// break parsing of the two that matter.
    func testIgnoresUnknownKeys() throws {
        let limit = try XCTUnwrap(AppleRateLimit(
            header: "user-hour-lim:7200;user-hour-rem:100;some-future-key:9;"))
        XCTAssertEqual(limit.remaining, 100)
    }

    func testRejectsGarbageAndAbsentHeader() {
        XCTAssertNil(AppleRateLimit(header: ""))
        XCTAssertNil(AppleRateLimit(header: "nonsense"))
        XCTAssertNil(AppleRateLimit(header: "user-hour-rem:5;"), "limit is required")
        XCTAssertNil(AppleRateLimit(header: "user-hour-lim:0;user-hour-rem:0;"),
                     "a zero ceiling is not a usable reading")
    }

    /// Apple has been observed returning a negative remainder when over budget.
    func testNegativeRemainingClampsToZero() throws {
        let limit = try XCTUnwrap(
            AppleRateLimit(header: "user-hour-lim:7200;user-hour-rem:-5;"))
        XCTAssertEqual(limit.remaining, 0)
        XCTAssertTrue(limit.isExhausted)
    }

    func testFractionRemaining() throws {
        let limit = try XCTUnwrap(
            AppleRateLimit(header: "user-hour-lim:1000;user-hour-rem:250;"))
        XCTAssertEqual(limit.fractionRemaining, 0.25, accuracy: 0.001)
    }
}

final class RateLimitBudgetTests: XCTestCase {

    func testNoDelayBeforeAnyReading() async {
        let budget = RateLimitBudget()
        let delay = await budget.recommendedDelay()
        XCTAssertEqual(delay, 0, "an unmeasured budget must not slow anything down")
    }

    func testUnparseableHeaderIsIgnored() async {
        let budget = RateLimitBudget()
        await budget.update(from: "garbage")
        let current = await budget.current
        XCTAssertNil(current)
    }

    func testNilHeaderIsIgnored() async {
        let budget = RateLimitBudget()
        await budget.update(from: nil)
        let current = await budget.current
        XCTAssertNil(current)
    }

    /// Plenty of budget must cost nothing: normal use is unaffected.
    func testAmpleBudgetAddsNoDelay() async {
        let budget = RateLimitBudget()
        await budget.update(from: "user-hour-lim:7200;user-hour-rem:7000;")
        let delay = await budget.recommendedDelay()
        XCTAssertEqual(delay, 0)
    }

    /// Below the conserve threshold the remainder is spread out rather than
    /// burned, so throughput degrades instead of hitting a wall of 429s.
    func testLowBudgetIntroducesSpacing() async {
        let budget = RateLimitBudget()
        await budget.update(from: "user-hour-lim:7200;user-hour-rem:100;")
        let delay = await budget.recommendedDelay()
        XCTAssertGreaterThan(delay, 0)
        // ~3600s of window spread over 100 requests.
        XCTAssertEqual(delay, 36, accuracy: 2)
    }

    func testScarcerBudgetSpacesFurtherApart() async {
        let generous = RateLimitBudget()
        await generous.update(from: "user-hour-lim:7200;user-hour-rem:1000;")

        let scarce = RateLimitBudget()
        await scarce.update(from: "user-hour-lim:7200;user-hour-rem:50;")

        let generousDelay = await generous.recommendedDelay()
        let scarceDelay = await scarce.recommendedDelay()
        XCTAssertLessThan(generousDelay, scarceDelay)
    }

    func testExhaustedBudgetBacksOff() async {
        let budget = RateLimitBudget()
        await budget.update(from: "user-hour-lim:7200;user-hour-rem:0;")
        let delay = await budget.recommendedDelay()
        XCTAssertEqual(delay, 60, "rolling window frees up gradually, so re-check")
    }

    func testDescribeReportsRemaining() async {
        let budget = RateLimitBudget()
        await budget.update(from: "user-hour-lim:7200;user-hour-rem:42;")
        let text = await budget.describe()
        XCTAssertEqual(text, "42 of 7200 requests left this hour")
    }

    /// A later reading replaces an earlier one, including when the budget
    /// recovers as the rolling window advances.
    func testLatestReadingWins() async {
        let budget = RateLimitBudget()
        await budget.update(from: "user-hour-lim:7200;user-hour-rem:10;")
        await budget.update(from: "user-hour-lim:7200;user-hour-rem:6000;")
        let remaining = await budget.current?.remaining
        let delay = await budget.recommendedDelay()
        XCTAssertEqual(remaining, 6000)
        XCTAssertEqual(delay, 0)
    }
}
