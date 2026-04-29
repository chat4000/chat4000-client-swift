import SwiftUI

struct VoiceWaveformView: View {
    let samples: [Float]
    let progress: Double
    let activeColor: Color
    let inactiveColor: Color
    var minimumHeight: CGFloat = 8
    var maximumHeight: CGFloat = 30

    var body: some View {
        GeometryReader { geometry in
            let count = max(samples.count, 1)
            let spacing: CGFloat = 2
            let totalSpacing = CGFloat(max(count - 1, 0)) * spacing
            let barWidth = max(2, (geometry.size.width - totalSpacing) / CGFloat(count))
            let progressX = geometry.size.width * CGFloat(min(max(progress, 0), 1))

            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(samples.enumerated()), id: \.offset) { index, sample in
                    let barMidX = CGFloat(index) * (barWidth + spacing) + (barWidth / 2)
                    Capsule()
                        .fill(barMidX <= progressX ? activeColor : inactiveColor)
                        .frame(
                            width: barWidth,
                            height: minimumHeight + (maximumHeight - minimumHeight) * CGFloat(max(0.08, sample))
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

struct VoicePlaybackStrip: View {
    let sourceKey: String
    let audioData: Data
    let waveform: [Float]
    let duration: TimeInterval?
    let activeColor: Color
    let inactiveColor: Color
    let backgroundColor: Color
    let textColor: Color
    var compact: Bool = false

    @State private var player = VoicePlaybackController()
    @State private var scrubProgress: Double?

    private var displayedProgress: Double {
        scrubProgress ?? player.progress
    }

    private var totalDuration: TimeInterval {
        if let duration, duration > 0.05 {
            return duration
        }
        return player.duration
    }

    private var displayedCurrentTime: TimeInterval {
        scrubProgress.map { totalDuration * $0 } ?? player.currentTime
    }

    private var displayedDurationText: String {
        if compact {
            let position = max(displayedCurrentTime, 0)
            let showsPosition = player.isPlaying || position > 0.05
            let seconds = showsPosition ? position : totalDuration
            return VoiceNoteFormatter.durationText(seconds)
        }
        return "\(VoiceNoteFormatter.durationText(displayedCurrentTime)) / \(VoiceNoteFormatter.durationText(totalDuration))"
    }

    private var rateButtonWidth: CGFloat {
        compact ? 42 : 50
    }

    private var playButtonSize: CGFloat {
        compact ? 28 : 32
    }

    private var waveformHeight: CGFloat {
        compact ? 28 : 34
    }

    private var playheadSize: CGFloat {
        compact ? 10 : 12
    }

    private var timerSpacing: CGFloat {
        compact ? 10 : 12
    }

    var body: some View {
        HStack(spacing: compact ? 8 : 10) {
            Button {
                Haptics.impact()
                DispatchQueue.main.async {
                    player.cycleRate()
                }
            } label: {
                Text(player.rate.label)
                    .font(AppFonts.caption)
                    .foregroundStyle(textColor)
                    .frame(width: rateButtonWidth)
                    .padding(.vertical, compact ? 4 : 6)
                    .background(Color.white.opacity(compact ? 0.08 : 0.12))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button {
                Haptics.impact()
                DispatchQueue.main.async {
                    player.togglePlayback()
                }
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: compact ? 12 : 14, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: playButtonSize, height: playButtonSize)
                    .background(Color.white)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            waveformStrip
                .frame(maxWidth: .infinity, minHeight: waveformHeight, maxHeight: waveformHeight)
                .padding(.trailing, compact ? 6 : 8)
                .layoutPriority(0)

            Text(displayedDurationText)
                .font(AppFonts.caption)
                .foregroundStyle(textColor.opacity(0.75))
                .monospacedDigit()
                .lineLimit(1)
                .layoutPriority(1)
        }
        .frame(maxWidth: compact ? 272 : 348, alignment: .leading)
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 6 : 10)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: compact ? 18 : 20))
        .onAppear {
            player.load(sourceKey: sourceKey, audioData: audioData, durationHint: duration)
        }
        .onChange(of: sourceKey) { _, newValue in
            player.load(sourceKey: newValue, audioData: audioData, durationHint: duration)
        }
    }

    @ViewBuilder
    private var waveformStrip: some View {
        GeometryReader { geometry in
            let progressX = geometry.size.width * CGFloat(displayedProgress)

            ZStack(alignment: .leading) {
                VoiceWaveformView(
                    samples: waveform,
                    progress: displayedProgress,
                    activeColor: activeColor,
                    inactiveColor: inactiveColor,
                    minimumHeight: compact ? 6 : 8,
                    maximumHeight: compact ? 22 : 28
                )

                Circle()
                    .fill(Color.white)
                    .frame(width: playheadSize, height: playheadSize)
                    .offset(
                        x: min(
                            max(progressX - (playheadSize / 2), 0),
                            geometry.size.width - playheadSize
                        )
                    )
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        let clamped = min(max(value.location.x / max(geometry.size.width, 1), 0), 1)
                        Haptics.impact()
                        DispatchQueue.main.async {
                            player.seek(to: clamped)
                        }
                    }
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let clamped = min(max(value.location.x / max(geometry.size.width, 1), 0), 1)
                        scrubProgress = clamped
                    }
                    .onEnded { value in
                        let clamped = min(max(value.location.x / max(geometry.size.width, 1), 0), 1)
                        Haptics.impact()
                        DispatchQueue.main.async {
                            player.seek(to: clamped)
                        }
                        scrubProgress = nil
                    }
            )
        }
        .clipped()
    }
}
