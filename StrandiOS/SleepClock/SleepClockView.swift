import StrandAnalytics
import StrandDesign
import SwiftUI

/// The bedside Sleep Clock: a near-black page that stays on all night, read with the phone lying on its
/// side. The time sits in the middle, the sleep battery stands on the right as eight gas-gauge pills that
/// light from the bottom as sleep is banked against the night's need, and one line says where the night
/// stands. Once full, the strap buzzes at the next light moment. A tap toggles between the dim night view
/// and a brighter readout; "I'm up" silences the strap; Exit needs two taps.
///
/// The iPhone target is portrait-only, so the page draws its landscape layout rotated a quarter turn
/// rather than asking the app to support landscape for one screen.
struct SleepClockView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var controller: SleepClockController
    let onClose: () -> Void

    @State private var exitArmedUntil: Date? = nil

    init(model: AppModel, nap: SleepClockController.NapPlan? = nil, onClose: @escaping () -> Void) {
        _controller = StateObject(wrappedValue: SleepClockController(model: model, nap: nap))
        self.onClose = onClose
    }

    private var isNap: Bool { controller.nap != nil }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                landscape(size: CGSize(width: geo.size.height, height: geo.size.width))
                    .frame(width: geo.size.height, height: geo.size.width)
                    .rotationEffect(.degrees(-90))
                    .frame(width: geo.size.width, height: geo.size.height)
                    .opacity(controller.peeking ? 1 : 0.55)
                    .animation(.easeInOut(duration: 0.6), value: controller.peeking)
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { controller.peek() }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
    }

    // MARK: Landscape page

    private func landscape(size: CGSize) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            ZStack {
                // The time block is centred on the whole page, both ways; the battery and the
                // controls are laid over it so they never push the clock off centre.
                VStack(spacing: 18) {
                    Text(Self.clockFormatter.string(from: context.date))
                        .font(StrandFont.display(min(104, size.height * 0.27)))
                        .tracking(StrandFont.displayTracking(84))
                        .foregroundStyle(StrandPalette.nightClockInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .accessibilityLabel(Text("Time \(Self.clockFormatter.string(from: context.date))"))
                    Text(statusLine(now: context.date))
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.nightClockInk)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if let stage = controller.snapshot?.stage, !controller.isBuzzing {
                        Text(Self.label(for: stage))
                            .font(StrandFont.overline)
                            .tracking(StrandFont.overlineTracking)
                            .foregroundStyle(StrandPalette.nightClockInk.opacity(0.7))
                    }
                    Text(needLine)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.nightClockInk.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: size.width * 0.5)
                HStack {
                    Spacer()
                    SleepBatteryGauge(fraction: controller.snapshot?.fraction ?? 0,
                                      settling: controller.snapshot?.asleepSince == nil)
                        .frame(width: 82, height: size.height * 0.64)
                        .padding(.trailing, size.width * 0.08)
                }
                VStack {
                    Spacer()
                    controls
                        .padding(.bottom, 14)
                }
            }
        }
    }

    // MARK: Controls

    @ViewBuilder private var controls: some View {
        if controller.isBuzzing {
            Button {
                controller.acknowledgeWake()
                controller.stop()
                onClose()
            } label: {
                Text("I'm up")
                    .font(StrandFont.title2)
                    .foregroundStyle(Color.black)
                    .frame(maxWidth: 360, minHeight: 56)
                    .background(StrandPalette.nightClockInk, in: Capsule())
            }
            .accessibilityHint(Text("Stops the strap buzzing and closes the Sleep Clock"))
        } else {
            let armed = exitArmedUntil.map { $0 > Date() } ?? false
            Button {
                if armed {
                    controller.stop()
                    onClose()
                } else {
                    exitArmedUntil = Date().addingTimeInterval(3)
                }
            } label: {
                Text(armed ? "Tap again to exit" : "Exit")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.nightClockInk.opacity(0.8))
                    .frame(minWidth: 120, minHeight: 44)
            }
            .accessibilityHint(Text("Closes the Sleep Clock; tap twice"))
        }
    }

    // MARK: Copy — ONE resolver for the night's state, read by the line and the accessibility label.

    private func statusLine(now: Date) -> String {
        guard let s = controller.snapshot else { return String(localized: "Starting…") }
        if controller.isBuzzing {
            return isNap ? String(localized: "Nap done! Let's go!") : String(localized: "100% Sleep! Let's go!")
        }
        if s.noSignal { return String(localized: "No signal from the strap") }
        guard s.asleepSince != nil else { return String(localized: "Settling in…") }
        let asleep = Self.duration(s.sleepSeconds)
        if isNap {
            if s.fraction >= 1 { return String(localized: "Napped \(asleep). Goal reached.") }
            let eta = now.addingTimeInterval(TimeInterval(s.secondsToFull))
            return String(localized: "Napping \(asleep). Done at about \(Self.clockFormatter.string(from: eta)).")
        }
        if s.fraction >= 1 {
            if controller.acknowledged { return String(localized: "Asleep \(asleep). Battery full.") }
            return controller.buzzAtFull
                ? String(localized: "Asleep \(asleep). Full — waiting for a light moment.")
                : String(localized: "Asleep \(asleep). Battery full.")
        }
        let eta = now.addingTimeInterval(TimeInterval(s.secondsToFull))
        return String(localized: "Asleep \(asleep). Full at about \(Self.clockFormatter.string(from: eta)).")
    }

    /// "Need 8h 45m tonight · 8h + 30m debt + 15m strain": what 100% means tonight and why.
    private var needLine: String {
        if let nap = controller.nap {
            let goal = Self.duration(nap.targetSeconds)
            let clears = min(Double(nap.targetSeconds) / 60, nap.debtMin)
            return clears >= 1
                ? String(localized: "Nap goal \(goal) · clears \(Self.duration(Int(clears * 60))) of sleep debt")
                : String(localized: "Nap goal \(goal)")
        }
        let b = controller.needBreakdown
        var parts = [Self.duration(Int(b.baselineMin * 60))]
        if b.debtMin >= 1 { parts.append(String(localized: "\(Self.duration(Int(b.debtMin * 60))) debt")) }
        if b.strainMin >= 1 { parts.append(String(localized: "\(Self.duration(Int(b.strainMin * 60))) strain")) }
        let total = Self.duration(controller.needSeconds)
        return parts.count == 1
            ? String(localized: "Need \(total) tonight")
            : String(localized: "Need \(total) tonight · \(parts.joined(separator: " + "))")
    }

    private static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private static func label(for stage: SleepBatteryTracker.Stage) -> String {
        switch stage {
        case .awake: return String(localized: "Awake")
        case .light: return String(localized: "Light sleep")
        case .deep:  return String(localized: "Deep sleep")
        case .rem:   return String(localized: "REM")
        }
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()
}

/// The sleep battery as a gas gauge: eight horizontal pills stacked in a vertical cell, lit
/// from the bottom as the night fills. Lit pills are red through 74%, amber from 75% to 84% and green from
/// 85%, in the same muted night inks as the clock so the gauge adds no light to the room.
struct SleepBatteryGauge: View {
    let fraction: Double
    /// Before onset: empty pills with a dash rather than a hard 0%.
    let settling: Bool

    static let pillCount = 8

    private var clamped: Double { min(1, max(0, fraction)) }
    private var percent: Int { Int((clamped * 100).rounded()) }
    private var litCount: Int { settling ? 0 : Int((clamped * Double(Self.pillCount)).rounded()) }
    private var fill: Color {
        if percent >= 85 { return StrandPalette.nightClockFull }
        if percent >= 75 { return StrandPalette.nightClockMid }
        return StrandPalette.nightClockLow
    }

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 8) {
                ForEach((0..<Self.pillCount).reversed(), id: \.self) { i in
                    Capsule()
                        .fill(i < litCount ? fill : Color.clear)
                        .overlay(Capsule().stroke(StrandPalette.nightClockInk.opacity(i < litCount ? 0 : 0.5), lineWidth: 2))
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: .infinity)
                        .animation(.easeInOut(duration: 0.8), value: litCount)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(StrandPalette.nightClockInk, lineWidth: 4)
            )
            Text(settling ? "—" : "\(percent)%")
                .font(StrandFont.number(30))
                .foregroundStyle(StrandPalette.nightClockInk)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Sleep battery"))
        .accessibilityValue(Text(settling ? "Not asleep yet" : "\(percent) percent"))
    }
}

/// Presents the Sleep Clock from a screen that deliberately does not observe `AppModel` (Today keeps its
/// body free of per-sample churn): the cover picks the model up from the environment itself.
struct SleepClockCover: View {
    @EnvironmentObject private var model: AppModel
    let onClose: () -> Void

    var body: some View {
        SleepClockView(model: model, onClose: onClose)
    }
}
