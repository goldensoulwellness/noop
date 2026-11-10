import Combine
import Foundation
import StrandAnalytics
import UIKit

/// Drives the bedside Sleep Clock: keeps the screen (dim) and the strap link alive all night, feeds the
/// live heart rate and R-R stream into `SleepBatteryTracker`, re-anchors the estimate on the real stager
/// each time a history offload lands, and once the sleep battery is full buzzes the strap at the next
/// light moment (or after a grace period, so a full battery never waits forever).
///
/// Owned by `SleepClockView` for the life of the cover. `start()` and `stop()` are balanced: every hold
/// (idle timer, realtime HR, brightness) is released on stop, so leaving the clock restores the phone.
@MainActor
final class SleepClockController: ObservableObject {
    @Published private(set) var snapshot: SleepBatteryTracker.Snapshot?
    @Published private(set) var isBuzzing = false
    /// The user tapped "I'm up": no more buzzing this night.
    @Published private(set) var acknowledged = false
    /// A tap lifts the readout (brightness up a little, full ink) and it dims again by itself after
    /// `peekSeconds`; a second tap dims it right away. Buzzing never changes it; only a tap does.
    @Published private(set) var peeking = false

    /// UserDefaults keys for the Alarms-screen toggles.
    static let buzzAtFullKey = "sleepClock.buzzAtFull"

    /// Once full, wait at most this long for a light moment before buzzing anyway.
    static let graceSeconds = 30 * 60
    /// A nap buzzes the moment the goal is banked: a light-moment wait could add 15–30 minutes to a
    /// 20-minute nap, which defeats it.
    static let napGraceSeconds = 0
    /// Buzz cadence and cap: a strap buzz every 20 s for up to 10 minutes, then stop (the user is either
    /// up, or the strap is off the wrist).
    static let buzzIntervalSeconds: TimeInterval = 20
    static let maxBuzzes = 30
    /// Brightness while the readout is lifted, and how long it stays up before dimming on its own.
    static let peekBrightness: CGFloat = 0.3
    static let peekSeconds: TimeInterval = 8
    /// Bedtime hours: from 9 PM until 4 AM the Today screen offers the Sleep Clock in place of Start session.
    static let bedtimeStartHour = 21
    static let bedtimeEndHour = 4

    static func isBedtime(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= bedtimeStartHour || hour < bedtimeEndHour
    }
    /// Re-anchor on the real stager at most this often, even if offloads land more frequently.
    static let reanchorMinInterval: TimeInterval = 10 * 60

    let startedAt: Date
    let needSeconds: Int
    /// (baseline, debt, strain) minutes behind `needSeconds`, for the clock's need line.
    let needBreakdown: (baselineMin: Double, debtMin: Double, strainMin: Double)
    private var tracker: SleepBatteryTracker
    private weak var model: AppModel?
    private var cancellables = Set<AnyCancellable>()
    private var tickTimer: Timer?
    private var buzzTimer: Timer?
    private var peekTimer: Timer?
    private var buzzCount = 0
    private var lastReanchorAt: Date?
    private var savedBrightness: CGFloat = UIScreen.main.brightness
    private var running = false

    /// A daytime nap: how much sleep to bank before the strap buzzes, and the debt it is clearing.
    struct NapPlan: Equatable {
        let targetSeconds: Int
        let debtMin: Double
    }
    let nap: NapPlan?
    /// Once full, wait at most this long for a light moment before buzzing anyway (shorter for naps).
    let grace: Int

    init(model: AppModel, nap: NapPlan? = nil) {
        self.model = model
        self.nap = nap
        let now = Date()
        startedAt = now
        if let nap {
            grace = Self.napGraceSeconds
            needBreakdown = (Double(nap.targetSeconds) / 60, 0, 0)
            needSeconds = max(60, nap.targetSeconds)
            tracker = SleepBatteryTracker(needSeconds: needSeconds, startedAt: Int(now.timeIntervalSince1970))
            return
        }
        grace = Self.graceSeconds
        // Tonight's need the WHOOP way: the personal baseline every debt surface measures against
        // (upper-quartile, age-floored; 8 h until enough nights exist) + the sleep debt still owed from
        // the last 14 nights + extra for today's strain. A short night yesterday makes 100% take longer.
        let days = model.repo.days
        let baselineMin = SleepModel.debtNeedMin(days: days)
        let ledger = SleepModel.debtLedger(days: days, napSleepMinByDay: [:])
        let today = Repository.logicalDayKey(now)
        let strain = days.last(where: { $0.day == today })?.strain
        let needMin = SleepNeedTonight.minutes(baselineMin: baselineMin,
                                               debtMin: ledger.isDebt ? ledger.magnitudeMin : 0,
                                               strain: strain)
        needBreakdown = (baselineMin, ledger.isDebt ? ledger.magnitudeMin : 0, SleepNeedTonight.strainAddMin(strain))
        needSeconds = Int(needMin * 60)
        tracker = SleepBatteryTracker(needSeconds: needSeconds, startedAt: Int(now.timeIntervalSince1970))
    }

    var buzzAtFull: Bool {
        UserDefaults.standard.object(forKey: Self.buzzAtFullKey) as? Bool ?? true
    }

    // MARK: Lifecycle

    func start() {
        guard !running, let model else { return }
        running = true
        ScreenIdle.hold(.sleepClock, true)
        savedBrightness = UIScreen.main.brightness
        UIScreen.main.brightness = 0
        model.startRealtimeHR()
        model.ble.syncNow()

        let live = model.live
        live.$heartRate
            .compactMap { $0 }
            .sink { [weak self] hr in self?.tracker.add(hr: hr, at: Int(Date().timeIntervalSince1970)) }
            .store(in: &cancellables)
        live.$rrSeq
            .dropFirst()
            .sink { [weak self, weak live] _ in
                guard let self, let live else { return }
                self.tracker.add(rrMs: live.rr, at: Int(Date().timeIntervalSince1970))
            }
            .store(in: &cancellables)
        live.$lastSyncedAt
            .dropFirst()
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] _ in Task { await self?.reanchor() } }
            .store(in: &cancellables)

        tickTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
    }

    func stop() {
        guard running else { return }
        running = false
        stopBuzzing()
        peekTimer?.invalidate(); peekTimer = nil
        tickTimer?.invalidate(); tickTimer = nil
        cancellables.removeAll()
        model?.stopRealtimeHR()
        UIScreen.main.brightness = savedBrightness
        ScreenIdle.hold(.sleepClock, false)
    }

    /// "I'm up": stop the strap and keep it quiet for the rest of this clock session.
    func acknowledgeWake() {
        acknowledged = true
        stopBuzzing()
    }

    func peek() {
        peekTimer?.invalidate(); peekTimer = nil
        if peeking {
            dimNow()
            return
        }
        peeking = true
        UIScreen.main.brightness = Self.peekBrightness
        peekTimer = Timer.scheduledTimer(withTimeInterval: Self.peekSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dimNow() }
        }
    }

    private func dimNow() {
        peeking = false
        if running { UIScreen.main.brightness = 0 }
    }

    // MARK: Ticking

    private func tick() {
        var now = Int(Date().timeIntervalSince1970)
        #if DEBUG
        if let demoNow = demoStep() { now = demoNow }
        #endif
        let snap = tracker.snapshot(at: now)
        snapshot = snap
        guard buzzAtFull, !acknowledged, !isBuzzing, snap.fraction >= 1, let fullAt = snap.fullAt else { return }
        if nap != nil || snap.goodWakeMoment || now - fullAt >= grace {
            startBuzzing()
        }
    }

    private func startBuzzing() {
        isBuzzing = true
        buzzCount = 0
        // While the strap is buzzing, a double tap on it means "I'm up" — the same gesture that
        // silences the strap's own alarm — and must not fall through to the user's double-tap action
        // (which, on iPhone, would ping the phone across the bedroom).
        model?.strapDoubleTapOverride = { [weak self] in self?.acknowledgeWake() }
        claimedStrapTap = true
        buzzOnce()
        buzzTimer = Timer.scheduledTimer(withTimeInterval: Self.buzzIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.buzzOnce() }
        }
    }

    private func buzzOnce() {
        guard buzzCount < Self.maxBuzzes else { stopBuzzing(); return }
        buzzCount += 1
        model?.buzzStrapOnce()
    }

    private func stopBuzzing() {
        buzzTimer?.invalidate(); buzzTimer = nil
        isBuzzing = false
        if claimedStrapTap {
            model?.strapDoubleTapOverride = nil
            claimedStrapTap = false
        }
    }

    private var claimedStrapTap = false

    #if DEBUG
    // MARK: Demo night (debug builds only)

    /// Screenshot aid: `defaults write <bundle> sleepClock.demoStepMinutes -float 60` plays a synthetic
    /// night through the tracker, banking that many minutes of sleep per tick (cycling deep / light / REM
    /// heart rates), so the gauge can be captured filling without a strap. Returns the synthetic "now".
    private var demoCursor: Int?
    private func demoStep() -> Int? {
        let step = Int(UserDefaults.standard.double(forKey: "sleepClock.demoStepMinutes"))
        guard step > 0 else { return nil }
        if demoCursor == nil {
            demoFeed(from: tracker.startedAt, minutes: 10, bpm: 72, jitter: 2, rrSpread: 10)
            demoCursor = tracker.startedAt + 600
        }
        guard let cursor = demoCursor else { return nil }
        let hour = (cursor - tracker.startedAt) / 3_600
        let profile: [(bpm: Int, jitter: Int, rr: Int)] = [(55, 0, 60), (59, 1, 20), (63, 4, 10), (57, 1, 20)]
        let p = profile[hour % profile.count]
        demoFeed(from: cursor, minutes: step, bpm: p.bpm, jitter: p.jitter, rrSpread: p.rr)
        demoCursor = cursor + step * 60
        return demoCursor
    }

    private func demoFeed(from: Int, minutes: Int, bpm: Int, jitter: Int, rrSpread: Int) {
        for s in 0..<(minutes * 60) {
            let ts = from + s
            let wobble = jitter == 0 ? 0 : ((s * 7) % (2 * jitter + 1)) - jitter
            tracker.add(hr: bpm + wobble, at: ts)
            let base = 60_000 / max(1, bpm + wobble)
            tracker.add(rrMs: [base + (s % 2 == 0 ? rrSpread : -rrSpread)], at: ts)
        }
    }
    #endif

    // MARK: Re-anchoring on the real stager

    /// After an offload, stage the night so far with the real stager (motion + cardio) and hand its verdict
    /// to the tracker. Skips when the offload brought too little motion for the stager to trust.
    private func reanchor() async {
        guard running, let model else { return }
        if let last = lastReanchorAt, Date().timeIntervalSince(last) < Self.reanchorMinInterval { return }
        lastReanchorAt = Date()
        let from = Int(startedAt.timeIntervalSince1970) - 3_600
        let to = Int(Date().timeIntervalSince1970)
        let grav = await model.repo.gravitySamplesUnion(from: from, to: to)
        guard grav.count >= max(20, (to - from) / 120) else { return }
        let hr = await model.repo.hrSamples(from: from, to: to, limit: 200_000)
        let rr = await model.repo.rrIntervals(from: from, to: to, limit: 200_000)
        let tz = TimeZone.current.secondsFromGMT()
        let useV2 = PuffinExperiment.experimentalSleepV2Enabled
        let sessions = await Task.detached(priority: .utility) {
            SleepStager.detectSleep(hr: hr, rr: rr, gravity: grav, tzOffsetSeconds: tz, useSleepStagerV2: useV2)
        }.value
        let clockStart = Int(startedAt.timeIntervalSince1970)
        guard running, let night = sessions.last(where: { $0.end > clockStart }) else { return }
        let asleep = night.stages.filter { $0.stage != "wake" }.reduce(0) { $0 + max(0, $1.end - $1.start) }
        tracker.anchor(asleepSince: night.start, sleepSeconds: asleep, anchorTs: night.end)
        tick()
    }
}
