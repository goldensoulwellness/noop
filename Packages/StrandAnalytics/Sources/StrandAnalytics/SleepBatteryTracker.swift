import Foundation

/// Live, in-night sleep estimate for the bedside Sleep Clock: fed the strap's realtime heart rate and R-R
/// intervals as they arrive, it keeps a running "sleep so far", a coarse current stage, and the
/// **sleep battery** — sleep so far as a fraction of the night's need.
///
/// This is deliberately NOT the nightly stager. `SleepStager` / `SleepStagerV2` stage a finished night from
/// the offloaded motion + cardio streams; motion is not streamed live, so overnight the only fresh signals
/// are heart rate (~1 Hz) and R-R. The tracker therefore works in one-minute epochs on heart rate relative to
/// the night's own floor plus RMSSD, a heuristic that is honest about being an estimate. Whenever a history
/// offload lands mid-night the app re-runs the real stager over the night so far and hands the result in
/// through `anchor(...)`; from that point the tracker only estimates the tail after the anchor.
///
/// Pure value type, no clock: every input carries its own timestamp and `snapshot(at:)` takes the time, so
/// it is fully testable without a strap.
public struct SleepBatteryTracker: Equatable {
    public enum Stage: String, Equatable, CaseIterable {
        case awake, light, deep, rem
    }

    public struct Snapshot: Equatable {
        /// Estimated sleep onset (unix seconds), nil until the tracker has seen enough quiet minutes.
        public let asleepSince: Int?
        /// Seconds scored as asleep so far (awake and no-data minutes excluded).
        public let sleepSeconds: Int
        /// Stage of the latest completed epoch, nil before onset or while no heart rate is arriving.
        public let stage: Stage?
        /// Sleep battery, 0...1 (can exceed 1 once the need is met; the gauge clamps).
        public let fraction: Double
        /// Seconds of sleep still needed to reach the full battery; 0 once full.
        public let secondsToFull: Int
        /// When the battery first reached full, nil until it has.
        public let fullAt: Int?
        /// True when waking now would land in light/awake sleep or on a rising heart rate — the moment
        /// the Sleep Clock buzzes the strap once the battery is full.
        public let goodWakeMoment: Bool
        /// Lowest epoch-mean heart rate seen since onset.
        public let nightMinHR: Int?
        /// True when no heart-rate sample has arrived in the last two minutes (strap off or link down).
        public let noSignal: Bool
    }

    // MARK: Tuning (epoch = 60 s)

    static let epochSeconds = 60
    /// Consecutive quiet epochs before sleep onset is declared.
    static let onsetQuietEpochs = 10
    /// A quiet epoch sits this many bpm (or more) under the settling-in baseline…
    static let onsetDropBPM = 4
    /// …and moves no more than this from the previous epoch.
    static let onsetMaxStepBPM = 3
    /// Heart rate this far above the night floor reads as awake.
    static let awakeAboveFloorBPM = 12
    /// At or under this above the floor, with calm beats, reads as deep.
    static let deepAboveFloorBPM = 3
    /// REM band: raised but under the awake line, with restless beats.
    static let remAboveFloorBPM = 6
    /// The Android smart-wake rule: a rise of this much above the night floor marks a light moment.
    static let wakeRiseBPM = 6
    /// Epoch-mean heart rates under this are treated as a bad read, not a floor.
    static let minPlausibleBPM = 35
    /// No sample for this long and the epoch is "no data" (not scored either way).
    static let noSignalSeconds = 120

    struct Epoch: Equatable {
        var start: Int
        var hrSum = 0
        var hrCount = 0
        var hrMin = Int.max
        var hrMax = Int.min
        var rr: [Int] = []
        var meanHR: Int? { hrCount > 0 ? hrSum / hrCount : nil }
        var rmssd: Double? {
            guard rr.count >= 8 else { return nil }
            var acc = 0.0
            for i in 1..<rr.count { let d = Double(rr[i] - rr[i - 1]); acc += d * d }
            return (acc / Double(rr.count - 1)).squareRoot()
        }
    }

    public let needSeconds: Int
    public let startedAt: Int
    private(set) var epochs: [Epoch] = []
    private var lastSampleTs: Int?
    /// Settling-in baseline: the highest epoch mean seen before onset (lying awake in bed).
    private var baselineHR: Int?
    private var onsetTs: Int?
    /// Offloaded-and-staged truth up to `anchorTs`, from the real stager.
    private var anchorTs: Int?
    private var anchoredSleepSeconds = 0
    private var fullAt: Int?

    public init(needSeconds: Int, startedAt: Int) {
        self.needSeconds = max(60, needSeconds)
        self.startedAt = startedAt
    }

    // MARK: Inputs

    public mutating func add(hr: Int, at ts: Int) {
        guard hr >= Self.minPlausibleBPM, hr <= 220 else { return }
        var e = epoch(at: ts)
        e.hrSum += hr; e.hrCount += 1
        e.hrMin = min(e.hrMin, hr); e.hrMax = max(e.hrMax, hr)
        store(e)
        lastSampleTs = max(lastSampleTs ?? ts, ts)
    }

    public mutating func add(rrMs: [Int], at ts: Int) {
        let valid = rrMs.filter { $0 >= 300 && $0 <= 2_000 }
        guard !valid.isEmpty else { return }
        var e = epoch(at: ts)
        e.rr.append(contentsOf: valid)
        store(e)
    }

    /// The real stager's verdict for the night up to `anchorTs`: sleep began at `asleepSince` and
    /// `sleepSeconds` of it were scored asleep. Epochs at or before the anchor are no longer estimated.
    public mutating func anchor(asleepSince: Int, sleepSeconds: Int, anchorTs: Int) {
        guard anchorTs > (self.anchorTs ?? Int.min) else { return }
        onsetTs = min(onsetTs ?? asleepSince, asleepSince)
        self.anchorTs = anchorTs
        anchoredSleepSeconds = max(0, sleepSeconds)
    }

    // MARK: Output

    public mutating func snapshot(at now: Int) -> Snapshot {
        let noSignal = (lastSampleTs.map { now - $0 } ?? Int.max) >= Self.noSignalSeconds
        let onset = resolveOnset(now: now)
        var sleepSeconds = anchoredSleepSeconds
        var stage: Stage? = nil
        var floor: Int? = nil
        var staged: [Stage?] = []
        if let onset {
            let scoredFrom = max(onset, (anchorTs ?? Int.min) + 1)
            let completed = epochs.filter { $0.start + Self.epochSeconds <= now && $0.start >= scoredFrom }
            staged = Self.stage(completed, floor: &floor, nightEpochs: epochs.filter { $0.start >= onset })
            for s in staged where s != nil && s != .awake { sleepSeconds += Self.epochSeconds }
            stage = noSignal ? nil : staged.last ?? nil
        }
        let fraction = Double(sleepSeconds) / Double(needSeconds)
        // Full is dated by the sleep that reached it, not by whenever the clock next looked.
        if fraction >= 1, fullAt == nil { fullAt = now - (sleepSeconds - needSeconds) }
        let good: Bool = {
            guard onset != nil, !noSignal else { return false }
            if stage == .light || stage == .awake { return true }
            // A rising heart rate over the last two completed epochs is a light moment even mid-"deep".
            if let floor, staged.count >= 2, let last = epochs.last(where: { $0.start + Self.epochSeconds <= now })?.meanHR {
                return last - floor >= Self.wakeRiseBPM
            }
            return false
        }()
        return Snapshot(asleepSince: onset, sleepSeconds: sleepSeconds, stage: stage, fraction: fraction,
                        secondsToFull: max(0, needSeconds - sleepSeconds), fullAt: fullAt,
                        goodWakeMoment: good, nightMinHR: floor, noSignal: noSignal)
    }

    // MARK: Internals

    private func epoch(at ts: Int) -> Epoch {
        let start = ts - ((ts - startedAt) % Self.epochSeconds + Self.epochSeconds) % Self.epochSeconds
        if let last = epochs.last, last.start == start { return last }   // the common, in-order case
        return epochs.first { $0.start == start } ?? Epoch(start: start)
    }

    private mutating func store(_ e: Epoch) {
        if let last = epochs.last, last.start == e.start { epochs[epochs.count - 1] = e }
        else if let last = epochs.last, e.start > last.start { epochs.append(e) }
        else if let i = epochs.firstIndex(where: { $0.start == e.start }) { epochs[i] = e }
        else { epochs.append(e); epochs.sort { $0.start < $1.start } }
    }

    /// Onset: an anchor wins; otherwise the first run of `onsetQuietEpochs` quiet epochs.
    private mutating func resolveOnset(now: Int) -> Int? {
        if let onsetTs { return onsetTs }
        let completed = epochs.filter { $0.start + Self.epochSeconds <= now }
        var run = 0
        var prev: Int? = nil
        for e in completed {
            guard let hr = e.meanHR else { run = 0; prev = nil; continue }
            if run == 0 { baselineHR = max(baselineHR ?? hr, hr) }
            // The step check compares against the previous QUIET epoch: the drop into the first one is the point.
            let quiet = hr <= (baselineHR ?? hr) - Self.onsetDropBPM
                && (run == 0 || (prev.map { abs(hr - $0) <= Self.onsetMaxStepBPM } ?? true))
            run = quiet ? run + 1 : 0
            prev = hr
            if run >= Self.onsetQuietEpochs {
                onsetTs = e.start - (Self.onsetQuietEpochs - 1) * Self.epochSeconds
                return onsetTs
            }
        }
        return nil
    }

    /// Stage the completed epochs after onset against the night's heart-rate floor and RMSSD median.
    static func stage(_ scored: [Epoch], floor: inout Int?, nightEpochs: [Epoch]) -> [Stage?] {
        let means = nightEpochs.compactMap(\.meanHR)
        floor = means.min()
        guard let floor = floor else { return scored.map { _ in nil } }
        let rmssds = nightEpochs.compactMap(\.rmssd).sorted()
        let rmssdMedian = rmssds.isEmpty ? nil : rmssds[rmssds.count / 2]
        var out: [Stage?] = scored.map { e in
            guard let hr = e.meanHR else { return nil }
            let rel = hr - floor
            let spread = e.hrCount > 1 ? e.hrMax - e.hrMin : 0
            let calmBeats = (e.rmssd ?? 0) >= (rmssdMedian ?? 0)
            if rel >= awakeAboveFloorBPM { return .awake }
            if rel <= deepAboveFloorBPM && (e.rmssd == nil || calmBeats) && spread <= 6 { return .deep }
            if rel >= remAboveFloorBPM && (spread >= 5 || !calmBeats) { return .rem }
            return .light
        }
        // Smooth lone one-minute blips: a stage flanked by the same stage on both sides adopts it.
        if out.count >= 3 {
            for i in 1..<(out.count - 1) where out[i - 1] == out[i + 1] && out[i] != out[i - 1] && out[i - 1] != nil {
                out[i] = out[i - 1]
            }
        }
        return out
    }
}
