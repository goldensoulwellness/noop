import StrandAnalytics
import StrandDesign
import SwiftUI

/// The bedside Sleep Clock: a near-black full-screen page that stays on all night. A dim red time, a
/// battery that fills as sleep is banked against the night's need, one line that says where the night
/// stands, and — once the battery is full — the strap buzz at the next light moment. Tap anywhere for a
/// brief brighter readout; "I'm up" silences the strap; Exit needs two taps so a sleepy touch can't end it.
struct SleepClockView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var controller: SleepClockController
    let onClose: () -> Void

    @State private var exitArmedUntil: Date? = nil

    init(model: AppModel, onClose: @escaping () -> Void) {
        _controller = StateObject(wrappedValue: SleepClockController(model: model))
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TimelineView(.periodic(from: .now, by: 30)) { context in
                VStack(spacing: 28) {
                    Spacer(minLength: 0)
                    Text(Self.clockFormatter.string(from: context.date))
                        .font(StrandFont.display(84))
                        .tracking(StrandFont.displayTracking(84))
                        .foregroundStyle(StrandPalette.nightClockInk)
                        .accessibilityLabel(Text("Time \(Self.clockFormatter.string(from: context.date))"))
                    SleepBatteryGauge(fraction: controller.snapshot?.fraction ?? 0,
                                      settling: controller.snapshot?.asleepSince == nil)
                        .frame(width: 240, height: 110)
                    Text(statusLine(now: context.date))
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.nightClockInk)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 32)
                    if let stage = controller.snapshot?.stage, !controller.isBuzzing {
                        Text(Self.label(for: stage))
                            .font(StrandFont.overline)
                            .tracking(StrandFont.overlineTracking)
                            .foregroundStyle(StrandPalette.nightClockInk.opacity(0.7))
                    }
                    Spacer(minLength: 0)
                    controls
                        .padding(.bottom, 24)
                }
            }
            .opacity(controller.peeking || controller.isBuzzing ? 1 : 0.55)
            .animation(.easeInOut(duration: 0.6), value: controller.peeking)
        }
        .contentShape(Rectangle())
        .onTapGesture { controller.peek() }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
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
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(StrandPalette.nightClockInk, in: Capsule())
            }
            .padding(.horizontal, 40)
            .accessibilityHint(Text("Stops the strap buzzing and closes the Sleep Clock"))
        } else {
            let armed = exitArmedUntil.map { $0 > Date() } ?? false
            Button {
                if armed {
                    controller.stop()
                    onClose()
                } else {
                    exitArmedUntil = Date().addingTimeInterval(3)
                    controller.peek()
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
        if controller.isBuzzing { return String(localized: "Buzzing your strap. Tap I'm up.") }
        if s.noSignal { return String(localized: "No signal from the strap") }
        guard s.asleepSince != nil else { return String(localized: "Settling in…") }
        let asleep = Self.duration(s.sleepSeconds)
        if s.fraction >= 1 {
            if controller.acknowledged { return String(localized: "Asleep \(asleep). Battery full.") }
            return controller.buzzAtFull
                ? String(localized: "Asleep \(asleep). Full — waiting for a light moment.")
                : String(localized: "Asleep \(asleep). Battery full.")
        }
        let eta = now.addingTimeInterval(TimeInterval(s.secondsToFull))
        return String(localized: "Asleep \(asleep). Full at about \(Self.clockFormatter.string(from: eta)).")
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

/// The sleep battery: a horizontal cell with a nub, filling left to right. Red under 70%, amber to 85%,
/// green from 85% — the same muted night inks as the clock so the fill adds no light to the room.
struct SleepBatteryGauge: View {
    let fraction: Double
    /// Before onset: an empty outline with a faint pulse rather than a hard 0%.
    let settling: Bool

    private var clamped: Double { min(1, max(0, fraction)) }
    private var fill: Color {
        if clamped >= 0.85 { return StrandPalette.nightClockFull }
        if clamped >= 0.70 { return StrandPalette.nightClockMid }
        return StrandPalette.nightClockLow
    }

    var body: some View {
        GeometryReader { geo in
            let nubWidth: CGFloat = 12
            let body = CGRect(x: 0, y: 0, width: geo.size.width - nubWidth - 4, height: geo.size.height)
            let inset: CGFloat = 8
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(StrandPalette.nightClockInk, lineWidth: 4)
                    .frame(width: body.width, height: body.height)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(StrandPalette.nightClockInk)
                    .frame(width: nubWidth, height: body.height * 0.4)
                    .offset(x: body.width + 4)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(fill)
                    .frame(width: max(0, (body.width - inset * 2) * clamped), height: body.height - inset * 2)
                    .offset(x: inset)
                    .animation(.easeInOut(duration: 1.2), value: clamped)
                Text(settling ? "—" : "\(Int((clamped * 100).rounded()))%")
                    .font(StrandFont.number(40))
                    .foregroundStyle(StrandPalette.nightClockInk)
                    .frame(width: body.width, height: body.height)
                    .blendMode(.plusLighter)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Sleep battery"))
        .accessibilityValue(Text(settling ? "Not asleep yet" : "\(Int((clamped * 100).rounded())) percent"))
    }
}
