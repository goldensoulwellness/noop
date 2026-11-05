import Foundation

/// Tonight's sleep need the way WHOOP builds it: the personal baseline, plus the sleep debt still owed
/// from recent nights, plus extra for a hard day. The Sleep Clock's battery fills against THIS number,
/// so a short night yesterday makes 100% take longer tonight, and a big workout day asks for more.
///
/// Pure and constant-explicit so it can be checked without a strap or a database.
public enum SleepNeedTonight {
    /// Strain at or under this adds nothing; above it the add-on grows linearly…
    public static let strainFreeBelow = 10.0
    /// …to this many minutes at the top of the strain scale (21). WHOOP describes the strain add-on as
    /// "up to about an hour".
    public static let strainMaxAddMin = 60.0
    public static let strainScaleTop = 21.0
    /// Debt is already recency-weighted by the ledger; this cap keeps one catastrophic week from
    /// demanding an impossible night.
    public static let debtCapMin = 120.0

    /// Minutes of sleep needed tonight.
    /// - baselineMin: the personal need (upper-quartile, age-floored) every debt surface uses.
    /// - debtMin: the ledger's current debt magnitude (≥ 0; nil when there is no history).
    /// - strain: today's strain on the 0…21 scale (nil when none was scored).
    public static func minutes(baselineMin: Double, debtMin: Double?, strain: Double?) -> Double {
        let base = baselineMin.isFinite && baselineMin > 0 ? baselineMin : 480
        let debt = min(debtCapMin, max(0, debtMin ?? 0))
        return base + debt + strainAddMin(strain)
    }

    /// The strain add-on alone, for labelling.
    public static func strainAddMin(_ strain: Double?) -> Double {
        guard let s = strain, s.isFinite, s > strainFreeBelow else { return 0 }
        let t = min(1, (s - strainFreeBelow) / (strainScaleTop - strainFreeBelow))
        return (t * strainMaxAddMin).rounded()
    }
}
