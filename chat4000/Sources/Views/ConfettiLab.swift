import SwiftUI
#if canImport(ConfettiSwiftUI)
import ConfettiSwiftUI
#endif
#if canImport(Vortex)
import Vortex
#endif
#if canImport(SPConfetti)
import SPConfetti
#endif

// ─────────────────────────────────────────────────────────────────────────────
// TEMPORARY confetti comparison harness ("Confetti Lab"). A full-screen view that
// cycles through each candidate confetti library so we can pick the prettiest,
// then DELETE ALL OF THIS:
//   1. this file
//   2. the 3 SPM packages in project.yml (ConfettiSwiftUI / Vortex / SPConfetti)
//      and their entries in the iOSApp target `dependencies:`
//   3. the "Confetti Lab" row + fullScreenCover wiring in SettingsSheet
//   4. `xcodegen generate`
// ─────────────────────────────────────────────────────────────────────────────
struct ConfettiLabView: View {
    enum Style: Int, CaseIterable {
        // OSS libraries first, then our homemade Canvas variants.
        case ours, confettiSwiftUI, vortex, spConfetti
        case homeCannon, homeFireworks, homeEmoji, homeRain, homeBigSlow, homeDenseFast
        var title: String {
            switch self {
            case .ours: "Ours — Canvas (in-app)"
            case .confettiSwiftUI: "ConfettiSwiftUI · simibac · 2.4k★"
            case .vortex: "Vortex · twostraws (Paul Hudson)"
            case .spConfetti: "SPConfetti · ivanvorobei"
            case .homeCannon: "Homemade — Cannon burst 🎉"
            case .homeFireworks: "Homemade — Fireworks 🎆"
            case .homeEmoji: "Homemade — Emoji 🎊✨🥳"
            case .homeRain: "Homemade — Classic rain"
            case .homeBigSlow: "Homemade — Big & slow"
            case .homeDenseFast: "Homemade — Dense & fast"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var style: Style = .ours
    @State private var fireCount = 0
    @State private var spPresented = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            confettiLayer
                .allowsHitTesting(false)

            VStack(spacing: 14) {
                Spacer()
                Text(style.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text("\(style.rawValue + 1) / \(Style.allCases.count)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                HStack(spacing: 16) {
                    Button("Fire 🎉") { fire() }
                        .buttonStyle(.borderedProminent)
                    Button("Next style →") { nextStyle() }
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
        .onAppear { fire() }
    }

    @ViewBuilder private var confettiLayer: some View {
        switch style {
        case .ours:
            ConfettiView().id(fireCount)
        case .confettiSwiftUI:
            #if canImport(ConfettiSwiftUI)
            Color.clear.confettiCannon(counter: $fireCount, num: 60, radius: 420)
            #else
            EmptyView()
            #endif
        case .vortex:
            #if canImport(Vortex)
            VortexViewReader { proxy in
                VortexView(.confetti) {
                    Rectangle().fill(.white).frame(width: 16, height: 16).tag("square")
                    Circle().fill(.white).frame(width: 16, height: 16).tag("circle")
                }
                .onAppear { proxy.burst() }
                .onChange(of: fireCount) { proxy.burst() }
            }
            #else
            EmptyView()
            #endif
        case .spConfetti:
            #if canImport(SPConfetti)
            Color.clear.confetti(
                isPresented: $spPresented,
                animation: .fullWidthToDown,
                particles: [.triangle, .arc, .star, .heart],
                duration: 3
            )
            #else
            EmptyView()
            #endif
        case .homeCannon:
            LabConfetti(mode: .cannon, count: 130, sizeRange: 6...12, durRange: 1.6...2.5).id(fireCount)
        case .homeFireworks:
            LabConfetti(mode: .fireworks, count: 180, sizeRange: 5...9, durRange: 1.8...2.6).id(fireCount)
        case .homeEmoji:
            LabConfetti(mode: .cannon, count: 40, sizeRange: 22...34, durRange: 1.8...2.6,
                        emojis: ["🎉", "🎊", "✨", "🥳", "🎈"]).id(fireCount)
        case .homeRain:
            LabConfetti(mode: .rain, count: 110, sizeRange: 5...9, durRange: 2.4...3.2).id(fireCount)
        case .homeBigSlow:
            LabConfetti(mode: .rain, count: 45, sizeRange: 14...22, durRange: 3.0...4.0).id(fireCount)
        case .homeDenseFast:
            LabConfetti(mode: .rain, count: 260, sizeRange: 4...7, durRange: 1.2...1.9).id(fireCount)
        }
    }

    private func fire() {
        fireCount += 1
        if style == .spConfetti {
            spPresented = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { spPresented = true }
        }
    }

    private func nextStyle() {
        let all = Style.allCases
        style = all[(style.rawValue + 1) % all.count]
        spPresented = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { fire() }
    }
}

/// Homemade Canvas confetti with a few looks. One projectile model — each piece
/// has an origin + velocity + gravity — covers rain (fall from top), cannon
/// (burst up from the bottom), and fireworks (radial bursts from a few centers).
/// Lives here in the throwaway lab so deleting the file deletes everything.
private struct LabConfetti: View {
    enum Mode { case rain, cannon, fireworks }

    private struct Piece {
        var x0, y0, vx, vy, g: CGFloat   // fractions of width/height; velocity per second
        var size: CGFloat
        var delay, duration: Double
        var color: Color
        var emoji: String?
    }

    @State private var start = Date()
    private let pieces: [Piece]

    init(mode: Mode, count: Int, sizeRange: ClosedRange<CGFloat>,
         durRange: ClosedRange<Double>, emojis: [String]? = nil) {
        let palette: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .pink, .cyan]
        let centers: [(CGFloat, CGFloat)] = (0..<4).map { _ in
            (CGFloat.random(in: 0.2...0.8), CGFloat.random(in: 0.15...0.5))
        }
        pieces = (0..<count).map { _ in
            var x0: CGFloat = 0, y0: CGFloat = 0, vx: CGFloat = 0, vy: CGFloat = 0, g: CGFloat = 0
            var delay = 0.0
            switch mode {
            case .rain:
                x0 = .random(in: 0...1); y0 = -0.05
                vx = .random(in: -0.05...0.05); vy = .random(in: 0.15...0.32); g = 0.12
                delay = .random(in: 0...0.6)
            case .cannon:
                x0 = 0.5; y0 = 1.02
                let ang = Double.random(in: -1.0...1.0)   // radians from straight up
                let spd = Double.random(in: 0.8...1.5)
                vx = CGFloat(spd * sin(ang)); vy = CGFloat(-spd * cos(ang)); g = 1.1
                delay = .random(in: 0...0.15)
            case .fireworks:
                let c = centers.randomElement() ?? (0.5, 0.3)
                x0 = c.0; y0 = c.1
                let ang = Double.random(in: 0...(2 * .pi))
                let spd = Double.random(in: 0.25...0.6)
                vx = CGFloat(spd * cos(ang)); vy = CGFloat(spd * sin(ang)); g = 0.5
                delay = .random(in: 0...0.5)
            }
            return Piece(x0: x0, y0: y0, vx: vx, vy: vy, g: g,
                         size: .random(in: sizeRange), delay: delay,
                         duration: .random(in: durRange),
                         color: palette.randomElement() ?? .white, emoji: emojis?.randomElement())
        }
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let elapsed = timeline.date.timeIntervalSince(start)
                for p in pieces {
                    let t = elapsed - p.delay
                    guard t >= 0 else { continue }
                    let prog = t / p.duration
                    guard prog <= 1.2 else { continue }
                    let ct = CGFloat(t)
                    let x = (p.x0 + p.vx * ct) * size.width
                    let y = (p.y0 + p.vy * ct + 0.5 * p.g * ct * ct) * size.height
                    guard y < size.height + 50 else { continue }
                    let fade = prog < 0.85 ? 1.0 : max(0, 1 - (prog - 0.85) / 0.35)
                    ctx.opacity = fade
                    if let emoji = p.emoji {
                        ctx.draw(Text(emoji).font(.system(size: p.size)), at: CGPoint(x: x, y: y))
                    } else {
                        let rect = CGRect(x: x - p.size / 2, y: y - p.size / 2,
                                          width: p.size, height: p.size * 0.6)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(p.color))
                    }
                }
            }
        }
    }
}
