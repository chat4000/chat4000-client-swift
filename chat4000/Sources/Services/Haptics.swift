#if os(iOS)
import UIKit
import CoreHaptics
#endif
import Foundation

enum Haptics {
    #if os(iOS)
    @MainActor private static let impactGenerator = UIImpactFeedbackGenerator(style: .light)
    @MainActor private static let successGenerator = UINotificationFeedbackGenerator()
    @MainActor private static let errorGenerator = UINotificationFeedbackGenerator()
    /// Lazily-started Core Haptics engine for the rich `celebrate()` pattern.
    /// Held alive (an engine that deallocates can't play); recreated if the
    /// system stops it (auto-shutdown / interruption).
    @MainActor private static var celebrationEngine: CHHapticEngine?
    #endif

    @MainActor
    static func prime() {
        #if os(iOS)
        impactGenerator.prepare()
        successGenerator.prepare()
        errorGenerator.prepare()
        #endif
    }

    @MainActor
    static func impact() {
        #if os(iOS)
        impactGenerator.impactOccurred()
        impactGenerator.prepare()
        #endif
    }

    @MainActor
    static func success() {
        #if os(iOS)
        successGenerator.notificationOccurred(.success)
        successGenerator.prepare()
        #endif
    }

    @MainActor
    static func error() {
        #if os(iOS)
        errorGenerator.notificationOccurred(.error)
        errorGenerator.prepare()
        #endif
    }

    /// A rich celebratory burst for a "join" / new-session moment: four transient
    /// taps ramping intensity 0.3 → 1.0 and sharpness 0.5 → 0.9 over ~0.3s — a
    /// building swell, modeled on the MIT-licensed `celebration.ahap`
    /// (react-native-haptic-feedback). Falls back to the success notification on
    /// devices without Core Haptics (older hardware / Simulator).
    @MainActor
    static func celebrate() {
        #if os(iOS)
        guard let engine = startedCelebrationEngine() else {
            success()
            return
        }
        let steps = CelebrationStep.ramp
        let events = steps.map { step in
            CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: step.intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: step.sharpness)
                ],
                relativeTime: step.time
            )
        }
        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            success()
        }
        #endif
    }

    /// A triumphant "ta-da" for the connected/join moment: three escalating taps,
    /// a strong final hit, then a short swell (the native "Fanfare" pattern).
    /// Falls back to the success notification on hardware without Core Haptics.
    @MainActor
    static func fanfare() {
        #if os(iOS)
        guard let engine = startedCelebrationEngine() else {
            success()
            return
        }
        var events: [CHHapticEvent] = [
            transient(time: 0.00, intensity: 0.50, sharpness: 0.60),
            transient(time: 0.12, intensity: 0.65, sharpness: 0.70),
            transient(time: 0.24, intensity: 0.80, sharpness: 0.80),
            transient(time: 0.40, intensity: 1.00, sharpness: 0.95)
        ]
        events.append(CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.7),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6)
            ],
            relativeTime: 0.42, duration: 0.25))
        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            success()
        }
        #endif
    }

    #if os(iOS)
    /// One tap in the celebration ramp (a struct, not a tuple, to satisfy the
    /// 2-member tuple lint).
    private struct CelebrationStep {
        let time: TimeInterval
        let intensity: Float
        let sharpness: Float

        /// 4-tap building swell over ~0.3s, modeled on `celebration.ahap`.
        static let ramp: [CelebrationStep] = [
            CelebrationStep(time: 0.00, intensity: 0.3, sharpness: 0.50),
            CelebrationStep(time: 0.10, intensity: 0.5, sharpness: 0.63),
            CelebrationStep(time: 0.20, intensity: 0.7, sharpness: 0.77),
            CelebrationStep(time: 0.30, intensity: 1.0, sharpness: 0.90)
        ]
    }

    /// Build a single transient (sharp tap) event — keeps `fanfare()` tuple-free.
    private static func transient(time: TimeInterval, intensity: Float, sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
            ],
            relativeTime: time)
    }

    /// Get (or lazily create + start) the shared Core Haptics engine, or nil when
    /// the hardware can't do Core Haptics. The engine nils itself out on stop so a
    /// later call rebuilds it.
    @MainActor
    private static func startedCelebrationEngine() -> CHHapticEngine? {
        if let celebrationEngine { return celebrationEngine }
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return nil }
        do {
            let engine = try CHHapticEngine()
            engine.isAutoShutdownEnabled = true
            engine.stoppedHandler = { _ in
                Task { @MainActor in Haptics.celebrationEngine = nil }
            }
            engine.resetHandler = { [weak engine] in
                try? engine?.start()
            }
            try engine.start()
            celebrationEngine = engine
            return engine
        } catch {
            return nil
        }
    }
    #endif
}
