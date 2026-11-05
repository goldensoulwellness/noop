import XCTest
@testable import StrandAnalytics

/// Synthetic nights for the live Sleep Clock estimator. Per AGENTS.md, a derived signal must track a
/// VARYING input, so onset and the battery are recovered across several injected bedtimes, baselines,
/// floors and needs — never a single matching night.
final class SleepBatteryTrackerTests: XCTestCase {
    private let t0 = 1_800_000_000

    /// Feed one heart-rate sample a second (plus one R-R packet) from `from` for `minutes`, at `bpm`
    /// with a deterministic ±`jitter` wobble; `rrSpread` widens the beat-to-beat variation.
    private func feed(_ t: inout SleepBatteryTracker, from: Int, minutes: Int, bpm: Int,
                      jitter: Int = 1, rrSpread: Int = 40) {
        for s in 0..<(minutes * 60) {
            let ts = from + s
            let wobble = jitter == 0 ? 0 : ((s * 7) % (2 * jitter + 1)) - jitter
            t.add(hr: bpm + wobble, at: ts)
            let base = 60_000 / max(1, bpm + wobble)
            let alt = (s % 2 == 0) ? rrSpread : -rrSpread
            t.add(rrMs: [base + alt], at: ts)
        }
    }

    func testOnsetTracksVaryingBedtimes() {
        for (awakeMin, awakeBPM, sleepBPM) in [(15, 72, 58), (40, 80, 64), (5, 66, 52)] {
            var t = SleepBatteryTracker(needSeconds: 8 * 3600, startedAt: t0)
            feed(&t, from: t0, minutes: awakeMin, bpm: awakeBPM, jitter: 2)
            feed(&t, from: t0 + awakeMin * 60, minutes: 60, bpm: sleepBPM)
            let snap = t.snapshot(at: t0 + (awakeMin + 60) * 60)
            let expected = t0 + awakeMin * 60
            XCTAssertNotNil(snap.asleepSince, "night \(awakeMin)/\(awakeBPM)/\(sleepBPM)")
            XCTAssertLessThanOrEqual(abs((snap.asleepSince ?? 0) - expected), 3 * 60,
                                     "onset within 3 min for bedtime +\(awakeMin) min")
            XCTAssertEqual(snap.nightMinHR.map { abs($0 - sleepBPM) <= 2 }, true)
        }
    }

    func testBatteryFillsAgainstEachNeed() {
        for needHours in [6.0, 7.5, 9.0] {
            var t = SleepBatteryTracker(needSeconds: Int(needHours * 3600), startedAt: t0)
            feed(&t, from: t0, minutes: 10, bpm: 70, jitter: 2)
            feed(&t, from: t0 + 600, minutes: Int(needHours * 60) + 30, bpm: 56)
            let halfway = t0 + 600 + Int(needHours * 1800)
            let half = t.snapshot(at: halfway)
            XCTAssertEqual(half.fraction, 0.5, accuracy: 0.03, "need \(needHours)h at halfway")
            XCTAssertNil(half.fullAt)
            let end = t.snapshot(at: t0 + 600 + Int(needHours * 3600) + 20 * 60)
            XCTAssertGreaterThanOrEqual(end.fraction, 1.0)
            XCTAssertEqual(end.secondsToFull, 0)
            XCTAssertNotNil(end.fullAt)
            XCTAssertLessThanOrEqual(abs((end.fullAt ?? 0) - (t0 + 600 + Int(needHours * 3600))), 3 * 60)
        }
    }

    func testStagesFollowHeartRateAboveTheFloor() {
        var t = SleepBatteryTracker(needSeconds: 8 * 3600, startedAt: t0)
        feed(&t, from: t0, minutes: 10, bpm: 72, jitter: 2)
        var cursor = t0 + 600
        feed(&t, from: cursor, minutes: 30, bpm: 55, jitter: 0, rrSpread: 60); cursor += 1800   // deep: floor, calm, wide RMSSD
        feed(&t, from: cursor, minutes: 20, bpm: 59, jitter: 1, rrSpread: 20); cursor += 1200   // light
        feed(&t, from: cursor, minutes: 20, bpm: 63, jitter: 4, rrSpread: 10); cursor += 1200   // rem: raised, restless
        feed(&t, from: cursor, minutes: 10, bpm: 70, jitter: 2, rrSpread: 10); cursor += 600    // awake
        let afterDeep = t.snapshot(at: t0 + 600 + 1800)
        XCTAssertEqual(afterDeep.stage, .deep)
        XCTAssertFalse(afterDeep.goodWakeMoment, "deep is not a wake moment")
        let afterLight = t.snapshot(at: t0 + 600 + 1800 + 1200)
        XCTAssertEqual(afterLight.stage, .light)
        XCTAssertTrue(afterLight.goodWakeMoment)
        let afterREM = t.snapshot(at: t0 + 600 + 1800 + 1200 + 1200)
        XCTAssertEqual(afterREM.stage, .rem)
        XCTAssertTrue(afterREM.goodWakeMoment, "a heart rate well above the floor counts as a wake moment")
        let awake = t.snapshot(at: cursor)
        XCTAssertEqual(awake.stage, .awake)
        // Awake minutes are not sleep: 30 + 20 + 20 min scored, the last 10 not.
        XCTAssertEqual(awake.sleepSeconds, 70 * 60)
    }

    func testNoSignalGapIsNotScoredEitherWay() {
        var t = SleepBatteryTracker(needSeconds: 8 * 3600, startedAt: t0)
        feed(&t, from: t0, minutes: 10, bpm: 72, jitter: 2)
        feed(&t, from: t0 + 600, minutes: 60, bpm: 56)
        // 30 minutes of nothing (strap off / link down)…
        let gap = t.snapshot(at: t0 + 600 + 3600 + 900)
        XCTAssertTrue(gap.noSignal)
        XCTAssertNil(gap.stage)
        XCTAssertFalse(gap.goodWakeMoment)
        // …then sleep resumes.
        feed(&t, from: t0 + 600 + 3600 + 1800, minutes: 30, bpm: 56)
        let after = t.snapshot(at: t0 + 600 + 3600 + 1800 + 1800)
        XCTAssertFalse(after.noSignal)
        XCTAssertEqual(after.sleepSeconds, 90 * 60, "the gap added nothing")
    }

    func testAnchorFromTheRealStagerReplacesTheEstimate() {
        var t = SleepBatteryTracker(needSeconds: 8 * 3600, startedAt: t0)
        feed(&t, from: t0, minutes: 90, bpm: 62, jitter: 1)   // never drops: no onset on its own
        XCTAssertNil(t.snapshot(at: t0 + 90 * 60).asleepSince)
        // An offload staged the night: asleep since t0+20 min, 60 min scored through t0+85 min.
        t.anchor(asleepSince: t0 + 20 * 60, sleepSeconds: 60 * 60, anchorTs: t0 + 85 * 60)
        feed(&t, from: t0 + 90 * 60, minutes: 10, bpm: 60, jitter: 1)
        let snap = t.snapshot(at: t0 + 100 * 60)
        XCTAssertEqual(snap.asleepSince, t0 + 20 * 60)
        // 60 anchored minutes + the estimated tail (minutes 85…100, each at the floor → asleep).
        XCTAssertGreaterThanOrEqual(snap.sleepSeconds, 60 * 60 + 10 * 60)
        XCTAssertLessThanOrEqual(snap.sleepSeconds, 60 * 60 + 15 * 60)
        // An older anchor cannot roll it back.
        t.anchor(asleepSince: t0, sleepSeconds: 0, anchorTs: t0 + 30 * 60)
        XCTAssertEqual(t.snapshot(at: t0 + 100 * 60).asleepSince, t0 + 20 * 60)
    }

    func testImplausibleReadingsAreIgnored() {
        var t = SleepBatteryTracker(needSeconds: 8 * 3600, startedAt: t0)
        feed(&t, from: t0, minutes: 10, bpm: 70, jitter: 2)
        feed(&t, from: t0 + 600, minutes: 30, bpm: 56)
        t.add(hr: 12, at: t0 + 600 + 1700)
        t.add(hr: 240, at: t0 + 600 + 1701)
        let snap = t.snapshot(at: t0 + 600 + 1800)
        XCTAssertEqual(snap.nightMinHR.map { $0 >= 54 }, true, "a 12 bpm glitch is not the floor")
    }
}
