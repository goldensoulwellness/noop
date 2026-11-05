import StrandAnalytics
import WhoopStore
import StrandDesign
import SwiftUI

/// The Nap screen: how much sleep debt is owed, how much of it a nap can clear, a goal to pick, and one
/// Start button that opens the dark clock in nap mode. The clock banks sleep against the goal and buzzes
/// the strap at the next light moment once it is reached (ten-minute grace), so a nap ends on time
/// without an alarm clock.
///
/// Napping facts that shape the defaults: 20 minutes refreshes without grogginess, 90 minutes is one full
/// sleep cycle, and anything between risks waking in deep sleep — which is exactly what the light-moment
/// buzz is for. Naps after mid-afternoon eat into the night, so the screen says so after 3 PM.
struct NapView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var goalMinutes: Int
    @State private var showClock = false

    static let goalOptions = [20, 30, 45, 60, 90]
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

    /// Debt under a quarter hour: a 20-minute refresher. Otherwise the smallest option that clears the
    /// debt, capped at one full 90-minute cycle.
    static func recommendedGoal(debtMin: Double) -> Int {
        guard debtMin >= 15 else { return 20 }
        return goalOptions.first { Double($0) >= debtMin } ?? 90
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
                        .accessibilityHint(Text("Opens the dark nap clock; the strap buzzes when the goal is reached"))
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
                SegmentedPillControl(Self.goalOptions, selection: $goalMinutes, fillsAvailableWidth: true) { m in
                    m >= 60 ? "\(m / 60)h\(m % 60 == 0 ? "" : " \(m % 60)m")" : "\(m)m"
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
        case 20: return clears >= 1
            ? String(localized: "A quick refresher that clears \(Self.duration(Int(clears))) of debt. Light sleep only, so waking is easy.")
            : String(localized: "A quick refresher. Light sleep only, so waking is easy.")
        case 90: return clears >= 1
            ? String(localized: "One full sleep cycle that clears \(Self.duration(Int(clears))) of debt. The best nap for real catch-up.")
            : String(localized: "One full sleep cycle. The best nap for deep rest.")
        default: return clears >= 1
            ? String(localized: "Clears \(Self.duration(Int(clears))) of debt. The buzz waits for a light moment so you don't wake mid-deep-sleep.")
            : String(localized: "The buzz waits for a light moment so you don't wake mid-deep-sleep.")
        }
    }

    /// Settling in (about 10 min) + the goal + the light-moment wait (up to 10 min).
    private var buzzByLine: String {
        let latest = Date().addingTimeInterval(TimeInterval((10 + goalMinutes + 10) * 60))
        return String(localized: "Buzz by about \(Self.timeFormatter.string(from: latest)) at the latest.")
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
