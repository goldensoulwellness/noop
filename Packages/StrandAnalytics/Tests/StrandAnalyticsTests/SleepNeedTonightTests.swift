import XCTest
@testable import StrandAnalytics

/// Tonight's need must move with every input it claims to track: baseline, debt and strain.
final class SleepNeedTonightTests: XCTestCase {
    func testBaselineAloneWhenNothingOwedAndEasyDay() {
        for base in [420.0, 480.0, 540.0] {
            XCTAssertEqual(SleepNeedTonight.minutes(baselineMin: base, debtMin: 0, strain: 6), base)
            XCTAssertEqual(SleepNeedTonight.minutes(baselineMin: base, debtMin: nil, strain: nil), base)
        }
    }

    func testDebtRaisesTheNeedAndIsCapped() {
        XCTAssertEqual(SleepNeedTonight.minutes(baselineMin: 480, debtMin: 45, strain: nil), 525)
        XCTAssertEqual(SleepNeedTonight.minutes(baselineMin: 480, debtMin: 300, strain: nil), 480 + 120)
        XCTAssertEqual(SleepNeedTonight.minutes(baselineMin: 480, debtMin: -30, strain: nil), 480, "surplus never lowers the need")
    }

    func testStrainAddsUpToAnHour() {
        XCTAssertEqual(SleepNeedTonight.strainAddMin(8), 0)
        XCTAssertEqual(SleepNeedTonight.strainAddMin(10), 0)
        let mid = SleepNeedTonight.strainAddMin(15.5)
        XCTAssertGreaterThan(mid, 20); XCTAssertLessThan(mid, 40)
        XCTAssertEqual(SleepNeedTonight.strainAddMin(21), 60)
        XCTAssertEqual(SleepNeedTonight.strainAddMin(25), 60, "capped at the top of the scale")
    }

    func testBadBaselineFallsBackToEightHours() {
        XCTAssertEqual(SleepNeedTonight.minutes(baselineMin: 0, debtMin: 0, strain: nil), 480)
        XCTAssertEqual(SleepNeedTonight.minutes(baselineMin: .nan, debtMin: 0, strain: nil), 480)
    }
}
