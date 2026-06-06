import SwiftUI
#if os(iOS)
import UIKit
import CoreHaptics
#endif
#if canImport(Pulsar)
import Pulsar
#endif

// ─────────────────────────────────────────────────────────────────────────────
// TEMPORARY haptics audition harness ("Haptics Lab"). Cycles every candidate
// celebration "music" so we can feel them and pick ONE, then DELETE ALL OF THIS:
//   1. this file
//   2. the "Haptics Lab" row + cover in SettingsSheet
//   3. the `Pulsar` package in project.yml + the iOSApp `- package: Pulsar`
//      dependency, then `xcodegen generate`
//
// Three groups, cycled in order:
//   • Native — hand-coded CHHapticPattern celebrations (zero deps, ship-safe):
//     clean-room of react-native `celebration.ahap` (MIT) + Apple `Grow` (Apache)
//     + a few originals (fireworks / applause / notes-song / fanfare).
//   • Pulsar — software-mansion-labs/pulsar-ios presets (MIT), played by name via
//     `getByName(_:)`. This is the dep we'll rip out once a winner is chosen.
//   • Basic — the stock UIKit feedback generators, for reference.
// ─────────────────────────────────────────────────────────────────────────────
@MainActor
struct HapticsLabView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    private var entries: [LabEntry] { Self.makeEntries() }

    var body: some View {
        let items = entries
        let current = items.isEmpty ? nil : items[min(index, items.count - 1)]
        return ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                Spacer()
                Text("📳").font(.system(size: 56))
                Text(current?.title ?? "—")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text(current?.source ?? "")
                    .font(.caption2.smallCaps())
                    .foregroundStyle(.white.opacity(0.5))
                Text("\(items.isEmpty ? 0 : index + 1) / \(items.count)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                HStack(spacing: 12) {
                    Button("← Prev") { step(-1, items) }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    Button("Buzz 📳") { current?.play() }
                        .buttonStyle(.borderedProminent)
                    Button("Next →") { step(1, items) }
                        .buttonStyle(.bordered)
                        .tint(.white)
                }
                Button("Done") { dismiss() }
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 4)
                Spacer().frame(height: 60)
            }
            .padding()
        }
        .onAppear { current?.play() }
    }

    private func step(_ delta: Int, _ items: [LabEntry]) {
        guard !items.isEmpty else { return }
        index = (index + delta + items.count) % items.count
        items[index].play()
    }

    // MARK: - Entries

    /// One auditionable haptic: a title, a source tag, and how to fire it.
    private struct LabEntry: Identifiable {
        let id = UUID()
        let title: String
        let source: String
        let play: @MainActor () -> Void
    }

    @MainActor
    private static func makeEntries() -> [LabEntry] {
        var entries: [LabEntry] = []

        #if os(iOS)
        // ── Native clean-room celebrations (zero deps) ──────────────────────
        for native in LabHaptics.Celebration.allCases {
            entries.append(LabEntry(title: native.title, source: "native") {
                LabHaptics.play(native)
            })
        }
        #endif

        #if os(iOS) && canImport(Pulsar)
        // ── Pulsar presets (MIT dep — to be ripped out) ─────────────────────
        for name in pulsarCelebrations {
            entries.append(LabEntry(title: "Pulsar · \(name)", source: "pulsar") {
                LabPulsar.play(name)
            })
        }
        #endif

        #if os(iOS)
        // ── Basic UIKit feedback (reference) ────────────────────────────────
        for basic in BasicBuzz.allCases {
            entries.append(LabEntry(title: basic.title, source: "uikit") { basic.fire() })
        }
        #endif

        return entries
    }

    /// Pulsar presets with a celebratory / "arrival" flavor (names verified in
    /// pulsar-ios `PresetsWrapper.mapper`). Played generically via `getByName`.
    private static let pulsarCelebrations: [String] = [
        "Fanfare", "Triumph", "Finale", "Applause", "Flourish", "Herald", "Trumpet",
        "BalloonPop", "Burst", "Bloom", "Crescendo", "Ascent", "Charge", "Surge",
        "Swell", "Buildup", "Firecracker", "Spark", "Chime", "CoinDrop", "Summon",
        "Flare", "Ripple", "GuitarStrum", "Shockwave", "Explosion", "Wave",
        "TidalSurge", "Unfurl", "Ignition", "Cascade", "BassDrop"
    ]
}

#if os(iOS)
// MARK: - Basic UIKit buzzes (reference group)

private enum BasicBuzz: Int, CaseIterable {
    case light, medium, heavy, soft, rigid, success, warning, error, selection
    case doubleTap, heartbeat, rampUp

    var title: String {
        switch self {
        case .light: "Impact · Light"
        case .medium: "Impact · Medium"
        case .heavy: "Impact · Heavy"
        case .soft: "Impact · Soft"
        case .rigid: "Impact · Rigid"
        case .success: "Notification · Success"
        case .warning: "Notification · Warning"
        case .error: "Notification · Error"
        case .selection: "Selection tick"
        case .doubleTap: "Pattern · Double tap"
        case .heartbeat: "Pattern · Heartbeat"
        case .rampUp: "Pattern · Ramp up"
        }
    }

    @MainActor
    func fire() {
        switch self {
        case .light: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .medium: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .heavy: UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case .soft: UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        case .rigid: UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error: UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .selection: UISelectionFeedbackGenerator().selectionChanged()
        case .doubleTap:
            let g = UIImpactFeedbackGenerator(style: .medium)
            g.impactOccurred()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { g.impactOccurred() }
        case .heartbeat:
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            }
        case .rampUp:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            }
        }
    }
}

// MARK: - Native clean-room celebration patterns (Core Haptics, zero deps)

@MainActor
private enum LabHaptics {
    /// Each case is a short celebratory CHHapticPattern built in code.
    enum Celebration: CaseIterable {
        case celebrationRamp, growSwell, fireworks, applause, heartbeatThump, notesSong, fanfare

        var title: String {
            switch self {
            case .celebrationRamp: "Native · Celebration ramp (RN, MIT)"
            case .growSwell: "Native · Grow swell (Apple, Apache-2.0)"
            case .fireworks: "Native · Fireworks"
            case .applause: "Native · Applause"
            case .heartbeatThump: "Native · Heartbeat ×2"
            case .notesSong: "Native · Notes song"
            case .fanfare: "Native · Fanfare"
            }
        }
    }

    private static var engine: CHHapticEngine?

    static func play(_ celebration: Celebration) {
        guard let pattern = pattern(for: celebration) else { fallback(); return }
        guard let engine = startedEngine() else { fallback(); return }
        do {
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            fallback()
        }
    }

    private static func fallback() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    // MARK: pattern builders

    private static func pattern(for celebration: Celebration) -> CHHapticPattern? {
        switch celebration {
        case .celebrationRamp: return ramp()
        case .growSwell: return growSwell()
        case .fireworks: return fireworks()
        case .applause: return applause()
        case .heartbeatThump: return heartbeat()
        case .notesSong: return notesSong()
        case .fanfare: return fanfare()
        }
    }

    private static func transient(_ time: TimeInterval, _ intensity: Float, _ sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
        ], relativeTime: time)
    }

    /// react-native `celebration.ahap` (MIT): 4 taps building 0.3 → 1.0 over 0.3s.
    private static func ramp() -> CHHapticPattern? {
        let events = [
            transient(0.00, 0.3, 0.50),
            transient(0.10, 0.5, 0.63),
            transient(0.20, 0.7, 0.77),
            transient(0.30, 1.0, 0.90)
        ]
        return try? CHHapticPattern(events: events, parameters: [])
    }

    /// Apple `Grow.ahap` (Apache-2.0): a 0.6s continuous swell whose intensity
    /// curves 0 → 1 → 0.3 → 0.
    private static func growSwell() -> CHHapticPattern? {
        let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
        ], relativeTime: 0, duration: 0.6)
        let curve = CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: [
            .init(relativeTime: 0.0, value: 0.0),
            .init(relativeTime: 0.2, value: 1.0),
            .init(relativeTime: 0.4, value: 0.3),
            .init(relativeTime: 0.6, value: 0.0)
        ], relativeTime: 0)
        return try? CHHapticPattern(events: [event], parameterCurves: [curve])
    }

    /// A few spaced bursts, each a sharp pop + short rumble tail.
    private static func fireworks() -> CHHapticPattern? {
        var events: [CHHapticEvent] = []
        for (i, t) in [0.0, 0.22, 0.5].enumerated() {
            events.append(transient(t, 1.0, 0.9))
            events.append(CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.5 - Float(i) * 0.1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3)
            ], relativeTime: t + 0.02, duration: 0.14))
        }
        return try? CHHapticPattern(events: events, parameters: [])
    }

    /// Many quick light taps with jittered timing — a hand-clap flutter.
    private static func applause() -> CHHapticPattern? {
        let times: [TimeInterval] = [0, 0.04, 0.09, 0.13, 0.19, 0.24, 0.31, 0.38, 0.46, 0.55, 0.66, 0.78]
        let events = times.enumerated().map { idx, t in
            transient(t, idx.isMultiple(of: 2) ? 0.45 : 0.3, 0.8)
        }
        return try? CHHapticPattern(events: events, parameters: [])
    }

    /// Two heavy thumps, lub-dub.
    private static func heartbeat() -> CHHapticPattern? {
        let events = [
            transient(0.00, 1.0, 0.3),
            transient(0.16, 0.6, 0.2),
            transient(0.60, 1.0, 0.3),
            transient(0.76, 0.6, 0.2)
        ]
        return try? CHHapticPattern(events: events, parameters: [])
    }

    /// Clean-room of `notes.ahap`: a ~1.5s run of taps with cycling sharpness — a
    /// little "tune" you feel rather than hear.
    private static func notesSong() -> CHHapticPattern? {
        let sharpness: [Float] = [0.2, 0.4, 0.6, 0.93, 0.6, 0.4, 0.7, 1.0]
        var events: [CHHapticEvent] = []
        for i in 0..<16 {
            let t = Double(i) * 0.09
            events.append(transient(t, 0.55 + Float(i % 3) * 0.15, sharpness[i % sharpness.count]))
        }
        return try? CHHapticPattern(events: events, parameters: [])
    }

    /// Escalating three taps then a strong final hit + a short swell — "ta-da".
    private static func fanfare() -> CHHapticPattern? {
        var events = [
            transient(0.00, 0.5, 0.6),
            transient(0.12, 0.65, 0.7),
            transient(0.24, 0.8, 0.8),
            transient(0.40, 1.0, 0.95)
        ]
        events.append(CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.7),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6)
        ], relativeTime: 0.42, duration: 0.25))
        return try? CHHapticPattern(events: events, parameters: [])
    }

    private static func startedEngine() -> CHHapticEngine? {
        if let engine { return engine }
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return nil }
        do {
            let new = try CHHapticEngine()
            new.isAutoShutdownEnabled = true
            new.stoppedHandler = { _ in Task { @MainActor in LabHaptics.engine = nil } }
            new.resetHandler = { [weak new] in try? new?.start() }
            try new.start()
            engine = new
            return new
        } catch {
            return nil
        }
    }
}
#endif

#if os(iOS) && canImport(Pulsar)
// MARK: - Pulsar bridge (MIT dep — temporary, rip out with the package)

@MainActor
private enum LabPulsar {
    private static let pulsar = Pulsar()

    static func play(_ name: String) {
        guard pulsar.canPlayHaptics() else { return }
        pulsar.getPresets().getByName(name)?.play()
    }
}
#endif
