import XCTest
@testable import iLabelMac

final class UpdateCheckerTests: XCTestCase {
    func testNumericFieldComparisonBeatsStringOrder() {
        XCTAssertTrue(UpdateChecker.isVersion("1.1.34", newerThan: "1.1.9"))
        XCTAssertFalse(UpdateChecker.isVersion("1.1.9", newerThan: "1.1.34"))
    }

    func testEqualVersionsAreNotNewer() {
        XCTAssertFalse(UpdateChecker.isVersion("0.3.0", newerThan: "0.3.0"))
    }

    func testMissingFieldsCountAsZero() {
        XCTAssertTrue(UpdateChecker.isVersion("1.2", newerThan: "1.1.9"))
        XCTAssertFalse(UpdateChecker.isVersion("1.2", newerThan: "1.2.0"))
        XCTAssertTrue(UpdateChecker.isVersion("1.2.1", newerThan: "1.2"))
    }

    func testTagPrefixAndPrereleaseSuffixAreIgnored() {
        XCTAssertTrue(UpdateChecker.isVersion("v0.3.0", newerThan: "0.2.0"))
        XCTAssertTrue(UpdateChecker.isVersion("0.3.0-beta", newerThan: "0.2.9"))
    }

    func testMalformedInputNeverOffersDowngrade() {
        XCTAssertFalse(UpdateChecker.isVersion("", newerThan: "0.2.0"))
        XCTAssertFalse(UpdateChecker.isVersion("not-a-version", newerThan: "0.2.0"))
    }
}
