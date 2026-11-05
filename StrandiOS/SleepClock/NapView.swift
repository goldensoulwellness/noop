import StrandAnalytics
import WhoopStore
import StrandDesign
import SwiftUI

/// The Nap screen: how much sleep debt is owed, how much of it a nap can clear, a goal to pick, and one
/// Start button that opens the dark clock in nap mode. The clock banks sleep against the goal and buzzes
/// the strap the moment it is reached (no light-moment wait: that could stretch a 20-minute nap to 30+),
/// so a nap ends on time without an alarm clock.
///
/// Napping facts that shape the defaults: 20 minutes refreshes without grogginess, 90 minutes is one full
/// sleep cycle, and anything between risks waking in deep sleep, so the copy says so. Naps after
/// mid-afternoon eat into the night, so the screen says so after 3 PM.
struct NapView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var goalMinutes: Int
    @State private var showClock = false

    /// Slider stops: 10…90 in 5-minute steps. The labelled landmarks are the nap lengths worth knowing.
    static let goalOptions = Array(stride(from: 10, through: 90, by: 5))
    static let landmarks = [10, 20, 30, 45, 60, 90]
    static let lateNapHour = 15

    private let debtMin: Double

    init(days: [DailyMetric]) {
        let ledger = SleepModel.debtLedger(days: days, napSleepMinByDay: [:])
        var debt = ledger.isDebt ? ledger.magnitudeMin : 0
        #if DEBUG
        // Screenshot aid: `defaults write <bundle> sleepClock.demoDebtMin -float 30` pretends this much debt.
        let demo = UserDefaults.standard.double(forKey: "sleepClock.demoDebtMin")
        if demo > 0 { debt = demo }
        #endif
        debtMin = debt
        _goalMinutes = State(initialValue: Self.recommendedGoal(debtMin: debt))
    }

    /// Debt under ten minutes: a 20-minute refresher. Otherwise the exact debt (its own stop on the
    /// slider), capped at one full 90-minute cycle.
    static func recommendedGoal(debtMin: Double) -> Int {
        guard debtMin >= 10 else { return 20 }
        return min(90, Int(debtMin.rounded()))
    }

    /// The 5-minute stops plus, when the debt lands between them, a stop for the exact debt — so 23
    /// minutes owed offers a 23-minute nap instead of rounding to 25.
    static func options(debtMin: Double) -> [Int] {
        let exact = Int(debtMin.rounded())
        guard debtMin >= 10, exact < 90, !goalOptions.contains(exact) else { return goalOptions }
        return (goalOptions + [exact]).sorted()
    }

    /// Home-row subtitle: the one line that says whether a nap would pay off today.
    static func debtLine(days: [DailyMetric]) -> String {
        let ledger = SleepModel.debtLedger(days: days, napSleepMinByDay: [:])
        guard ledger.isDebt, ledger.magnitudeMin >= 1 else { return String(localized: "No sleep debt. A nap is a bonus.") }
        return String(localized: "\(Self.duration(Int(ledger.magnitudeMin))) of sleep debt to clear")
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    hero
                    VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                        debtCard
                        goalCard
                        if !model.ble.state.connected { strapNote }
                        Button { showClock = true } label: {
                            Label("Start Nap", systemImage: "moon.zzz.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(NoopButtonStyle(.primary, fullWidth: true))
                        .accessibilityHint(Text("Opens the dark nap clock; the strap buzzes the moment the goal is reached"))
                        Text("Lay the phone on its side, top to the left. Tap the screen to read it; it dims again by itself.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, NoopMetrics.cardPadding)
                    .padding(.bottom, NoopMetrics.cardPadding)
                }
            }
            .ignoresSafeArea(edges: .top)
            // Done floats over the picture, in the corner a thumb reaches first.
            Button { dismiss() } label: {
                Text("Done")
                    .font(StrandFont.headline)
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .background(.ultraThinMaterial.opacity(0.9), in: Capsule())
                    .environment(\.colorScheme, .dark)
            }
            .padding(.leading, NoopMetrics.cardPadding)
            .padding(.top, 12)
            .accessibilityLabel("Done")
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .fullScreenCover(isPresented: $showClock) {
            SleepClockView(model: model,
                           nap: .init(targetSeconds: goalMinutes * 60, debtMin: debtMin),
                           onClose: { showClock = false })
        }
    }

    // MARK: Hero — the nap crew, asleep on their cloud, with the page's one-line promise.

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            // Drawn as an overlay so the picture's natural width never widens the page: the clear
            // base owns the layout, the image just paints over it.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 360)
                .overlay { Image("napHero").resizable().scaledToFill() }
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                Text("Nap time")
                    .font(StrandFont.rounded(34, weight: .bold))
                    .foregroundStyle(Color.white)
                Text("Cuddle up. We'll buzz your wrist when you've had enough.")
                    .font(StrandFont.body)
                    .foregroundStyle(Color.white.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(NoopMetrics.cardPadding)
        }
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: NoopMetrics.cardRadius,
                                          bottomTrailingRadius: NoopMetrics.cardRadius,
                                          style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Nap time. Cuddle up. We'll buzz your wrist when you've had enough."))
    }

    // MARK: Cards

    private var debtCard: some View {
        NoopCard(tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sleep debt").strandOverline()
                Text(debtMin >= 1 ? Self.duration(Int(debtMin)) : String(localized: "None"))
                    .font(StrandFont.number(44))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(debtMin >= 1
                     ? String(localized: "Owed from the last 14 nights. A nap pays it back minute for minute, so tonight's 100% comes sooner.")
                     : String(localized: "You're caught up. A nap now is extra rest, and it will not count against tonight."))
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var goalCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Nap goal").strandOverline()
                CloudSlider(stops: Self.options(debtMin: debtMin),
                            landmarks: Self.landmarks,
                            special: debtMin >= 10 && debtMin < 90 ? Int(debtMin.rounded()) : nil,
                            selection: $goalMinutes)
                if debtMin >= 10, debtMin < 90 {
                    Text("★ \(Self.duration(Int(debtMin.rounded()))) is your exact debt.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Text(goalNote)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(buzzByLine)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                if Calendar.current.component(.hour, from: Date()) >= Self.lateNapHour {
                    Label("It's after 3 PM. A long nap now can push tonight's sleep later; 20 minutes is the safer pick.", systemImage: "sun.haze")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var strapNote: some View {
        Label("Your band isn't connected. Connect it first so the nap can be tracked and the buzz can reach your wrist.", systemImage: "antenna.radiowaves.left.and.right.slash")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.statusWarning)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Copy

    private var goalNote: String {
        let clears = min(Double(goalMinutes), debtMin)
        switch goalMinutes {
        case ..<20: return clears >= 1
            ? String(localized: "A micro-nap that clears \(Self.duration(Int(clears))) of debt. Barely under, so you pop right back up.")
            : String(localized: "A micro-nap. Barely under, so you pop right back up.")
        case 20...25: return clears >= 1
            ? String(localized: "A quick refresher that clears \(Self.duration(Int(clears))) of debt. Light sleep only, so waking is easy.")
            : String(localized: "A quick refresher. Light sleep only, so waking is easy.")
        case 85...: return clears >= 1
            ? String(localized: "One full sleep cycle that clears \(Self.duration(Int(clears))) of debt. The best nap for real catch-up.")
            : String(localized: "One full sleep cycle. The best nap for deep rest.")
        default: return clears >= 1
            ? String(localized: "Clears \(Self.duration(Int(clears))) of debt. You may land in deep sleep at this length, so give yourself a minute to come round.")
            : String(localized: "You may land in deep sleep at this length, so give yourself a minute to come round.")
        }
    }

    /// Falling asleep (about 10 min) + the goal. The buzz comes the moment the goal is banked.
    private var buzzByLine: String {
        let latest = Date().addingTimeInterval(TimeInterval((10 + goalMinutes) * 60))
        return String(localized: "Buzzes the moment you've banked \(Self.duration(goalMinutes)) of sleep — about \(Self.timeFormatter.string(from: latest)) if you drop off in 10 minutes.")
    }

    private static func duration(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? (m > 0 ? "\(h)h \(m)m" : "\(h)h") : "\(m)m"
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()
}

/// The nap-goal slider: a soft track with the nap lengths worth knowing marked underneath, and a little
/// cloud for a thumb that carries the chosen minutes. Drag or tap anywhere on the track; it snaps to the
/// nearest stop (5-minute steps, plus a starred stop for the exact sleep debt).
struct CloudSlider: View {
    let stops: [Int]
    let landmarks: [Int]
    /// A stop to mark with a star (the exact debt), if any.
    let special: Int?
    @Binding var selection: Int

    private static let cloudWidth: CGFloat = 76
    private static let cloudHeight: CGFloat = 54
    private static let trackY: CGFloat = 60
    private static let cloudY: CGFloat = 24
    private static let height: CGFloat = 84
    /// Short naps get half the track: 10–30 min is where the choice is fine-grained, 30–90 is coarse.
    private static let bendAt = 30.0

    private var lo: Double { Double(stops.first ?? 10) }
    private var hi: Double { Double(stops.last ?? 90) }

    var body: some View {
        GeometryReader { geo in
            let inset = Self.cloudWidth / 2
            let usable = max(1, geo.size.width - inset * 2)
            let x = inset + usable * fraction(of: Double(selection))
            ZStack(alignment: .topLeading) {
                // Track, with the filled part up to the cloud.
                Capsule()
                    .fill(StrandPalette.restColor.opacity(0.18))
                    .frame(width: usable + 8, height: 10)
                    .position(x: inset + usable / 2, y: Self.trackY)
                Capsule()
                    .fill(LinearGradient(colors: [StrandPalette.restColor.opacity(0.45), StrandPalette.restColor],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(10, x - inset + 4), height: 10)
                    .position(x: inset - 4 + max(10, x - inset + 4) / 2, y: Self.trackY)
                // Landmark ticks + labels.
                ForEach(landmarks, id: \.self) { m in
                    let tx = inset + usable * fraction(of: Double(m))
                    Circle()
                        .fill(m <= selection ? Color.white : StrandPalette.restColor.opacity(0.5))
                        .frame(width: 5, height: 5)
                        .position(x: tx, y: Self.trackY)
                    Text(Self.label(m))
                        .font(StrandFont.caption)
                        .foregroundStyle(m == selection ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                        .fixedSize()
                        .position(x: tx, y: Self.trackY + 18)
                }
                // The star for the exact debt, just under the track.
                if let special, !landmarks.contains(special) {
                    let sx = inset + usable * fraction(of: Double(special))
                    Image(systemName: "star.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(StrandPalette.statusWarning)
                        .position(x: sx, y: Self.trackY + 18)
                }
                // The cloud, floating above the track with a little stem down to it.
                Rectangle()
                    .fill(StrandPalette.restColor.opacity(0.35))
                    .frame(width: 2, height: Self.trackY - Self.cloudY - 10)
                    .position(x: x, y: (Self.trackY + Self.cloudY) / 2 - 2)
                ZStack {
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 66, weight: .regular))
                        .foregroundStyle(Color.white)
                        .shadow(color: StrandPalette.restColor.opacity(0.35), radius: 8, y: 4)
                    Text(Self.label(selection))
                        .font(StrandFont.rounded(16, weight: .bold))
                        .foregroundStyle(StrandPalette.restColor)
                        .offset(y: 4)
                }
                .frame(width: Self.cloudWidth, height: Self.cloudHeight)
                .position(x: x, y: Self.cloudY)
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selection)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let f = Double(min(1, max(0, (g.location.x - inset) / usable)))
                        let value = minutes(at: f)
                        let nearest = stops.min { abs(Double($0) - value) < abs(Double($1) - value) } ?? selection
                        if nearest != selection {
                            selection = nearest
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    }
            )
        }
        .frame(height: Self.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Nap goal"))
        .accessibilityValue(Text(Self.label(selection)))
        .accessibilityAdjustableAction { direction in
            guard let i = stops.firstIndex(of: selection) else { return }
            switch direction {
            case .increment: if i + 1 < stops.count { selection = stops[i + 1] }
            case .decrement: if i > 0 { selection = stops[i - 1] }
            @unknown default: break
            }
        }
    }

    /// Minutes → 0…1 along the track, bent at `bendAt` so the short end is not cramped.
    private func fraction(of value: Double) -> CGFloat {
        let bend = min(max(Self.bendAt, lo), hi)
        if value <= bend {
            return CGFloat(0.5 * (value - lo) / max(1, bend - lo))
        }
        return CGFloat(0.5 + 0.5 * (value - bend) / max(1, hi - bend))
    }

    private func minutes(at f: Double) -> Double {
        let bend = min(max(Self.bendAt, lo), hi)
        return f <= 0.5 ? lo + (bend - lo) * (f / 0.5) : bend + (hi - bend) * ((f - 0.5) / 0.5)
    }

    static func label(_ m: Int) -> String {
        m >= 60 ? "\(m / 60)h\(m % 60 == 0 ? "" : " \(m % 60)m")" : "\(m)m"
    }
}
