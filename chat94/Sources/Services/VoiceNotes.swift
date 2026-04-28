import AVFoundation
import Foundation

enum VoiceNoteConstants {
    static let mimeType = "audio/mp4"
    static let waveformSampleCount = 48
    static let meterUpdateInterval = Duration.milliseconds(50)
}

enum VoicePlaybackRate: Float, CaseIterable, Codable {
    case one = 1.0
    case onePointFive = 1.5
    case two = 2.0

    var label: String {
        switch self {
        case .one: "1x"
        case .onePointFive: "1.5x"
        case .two: "2x"
        }
    }

    var next: VoicePlaybackRate {
        switch self {
        case .one: .onePointFive
        case .onePointFive: .two
        case .two: .one
        }
    }
}

struct RecordedVoiceClip: Equatable {
    let url: URL
    let data: Data
    let duration: TimeInterval
    let waveform: [Float]
    let mimeType: String

    func removeLocalFile() {
        try? FileManager.default.removeItem(at: url)
    }
}

enum VoiceNoteFormatter {
    static func durationText(_ duration: TimeInterval) -> String {
        let rounded = max(Int(duration.rounded()), 0)
        let minutes = rounded / 60
        let seconds = rounded % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    static func recordingDurationText(_ duration: TimeInterval) -> String {
        let clamped = max(duration, 0)
        let minutes = Int(clamped) / 60
        let seconds = Int(clamped) % 60
        let hundredths = Int((clamped * 100).truncatingRemainder(dividingBy: 100))
        return String(format: "%d:%02d.%02d", minutes, seconds, hundredths)
    }
}

enum VoiceWaveformCodec {
    static func encode(_ samples: [Float]) -> Data? {
        try? JSONEncoder().encode(samples)
    }

    static func decode(_ data: Data?) -> [Float]? {
        guard let data else { return nil }
        return try? JSONDecoder().decode([Float].self, from: data)
    }
}

enum VoiceWaveformBuilder {
    static func normalize(decibels: Float) -> Float {
        let clamped = max(decibels, -60)
        return max(0.08, min(1, 1 + (clamped / 60)))
    }

    static func downsample(_ samples: [Float], targetCount: Int = VoiceNoteConstants.waveformSampleCount) -> [Float] {
        guard !samples.isEmpty else {
            return Array(repeating: 0.12, count: targetCount)
        }

        if samples.count <= targetCount {
            return samples + Array(repeating: samples.last ?? 0.12, count: max(0, targetCount - samples.count))
        }

        let bucketSize = Double(samples.count) / Double(targetCount)
        return (0..<targetCount).map { index in
            let start = Int((Double(index) * bucketSize).rounded(.down))
            let end = Int((Double(index + 1) * bucketSize).rounded(.down))
            let slice = samples[start..<max(start + 1, min(end, samples.count))]
            return slice.reduce(0, +) / Float(slice.count)
        }
    }

    static func decodeWaveform(from audioData: Data, targetCount: Int = VoiceNoteConstants.waveformSampleCount) -> [Float] {
        do {
            let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
            try audioData.write(to: temporaryURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }

            let file = try AVAudioFile(forReading: temporaryURL)
            let format = file.processingFormat
            let frameCount = AVAudioFrameCount(file.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                return downsample([], targetCount: targetCount)
            }

            try file.read(into: buffer)
            guard let channelData = buffer.floatChannelData?[0] else {
                return downsample([], targetCount: targetCount)
            }

            let sampleCount = Int(buffer.frameLength)
            guard sampleCount > 0 else {
                return downsample([], targetCount: targetCount)
            }

            let samples = UnsafeBufferPointer(start: channelData, count: sampleCount)
            let bucketSize = max(1, sampleCount / targetCount)
            var output: [Float] = []
            output.reserveCapacity(targetCount)

            var index = 0
            while index < sampleCount {
                let end = min(index + bucketSize, sampleCount)
                let slice = samples[index..<end]
                let average = slice.reduce(Float.zero) { partial, value in
                    partial + abs(value)
                } / Float(slice.count)
                output.append(max(0.08, min(1, average * 4.5)))
                index = end
            }

            return downsample(output, targetCount: targetCount)
        } catch {
            return downsample([], targetCount: targetCount)
        }
    }
}

@MainActor
@Observable
final class VoiceNoteRecorder {
    private(set) var isRecording = false
    private(set) var liveWaveform: [Float] = Array(repeating: 0.12, count: VoiceNoteConstants.waveformSampleCount)
    private(set) var duration: TimeInterval = 0

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var meterSamples: [Float] = []
    @ObservationIgnored private var currentURL: URL?

    deinit {
        meterTask?.cancel()
    }

    func start() async throws {
        guard !isRecording else { return }
        let granted = await requestPermission()
        guard granted else {
            throw VoiceNoteError.permissionDenied
        }

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)
        #endif

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        recorder.record()

        self.recorder = recorder
        currentURL = url
        meterSamples = []
        liveWaveform = Array(repeating: 0.12, count: VoiceNoteConstants.waveformSampleCount)
        duration = 0
        isRecording = true

        meterTask?.cancel()
        meterTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.isRecording {
                try? await Task.sleep(for: VoiceNoteConstants.meterUpdateInterval)
                guard let recorder = self.recorder else { continue }
                recorder.updateMeters()
                let sample = VoiceWaveformBuilder.normalize(decibels: recorder.averagePower(forChannel: 0))
                self.meterSamples.append(sample)
                self.liveWaveform = VoiceWaveformBuilder.downsample(self.meterSamples)
                self.duration = recorder.currentTime
            }
        }
    }

    func stop() async -> RecordedVoiceClip? {
        guard isRecording, let recorder, let currentURL else { return nil }

        meterTask?.cancel()
        meterTask = nil
        recorder.stop()

        let duration = recorder.currentTime
        let waveform = VoiceWaveformBuilder.downsample(meterSamples)

        self.recorder = nil
        self.currentURL = nil
        self.isRecording = false
        self.duration = 0
        self.liveWaveform = Array(repeating: 0.12, count: VoiceNoteConstants.waveformSampleCount)
        self.meterSamples = []

        #if os(iOS)
        Task { @MainActor in
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
        #endif

        let data = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: currentURL)
        }.value

        guard let data else {
            try? FileManager.default.removeItem(at: currentURL)
            return nil
        }

        return RecordedVoiceClip(
            url: currentURL,
            data: data,
            duration: duration,
            waveform: waveform,
            mimeType: VoiceNoteConstants.mimeType
        )
    }

    func cancel() {
        meterTask?.cancel()
        meterTask = nil
        recorder?.stop()
        if let currentURL {
            try? FileManager.default.removeItem(at: currentURL)
        }
        recorder = nil
        currentURL = nil
        isRecording = false
        duration = 0
        liveWaveform = Array(repeating: 0.12, count: VoiceNoteConstants.waveformSampleCount)
        meterSamples = []
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }

    private func requestPermission() async -> Bool {
        #if os(iOS)
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
        #else
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        #endif
    }
}

@MainActor
@Observable
final class VoicePlaybackController {
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    var rate: VoicePlaybackRate = .one {
        didSet {
            player?.enableRate = true
            player?.rate = rate.rawValue
        }
    }

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var sourceKey: String?

    deinit {
        progressTask?.cancel()
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    func load(sourceKey: String, audioData: Data, durationHint: TimeInterval? = nil) {
        guard self.sourceKey != sourceKey else { return }

        stop()
        do {
            let player = try AVAudioPlayer(data: audioData)
            player.enableRate = true
            player.prepareToPlay()
            player.rate = rate.rawValue
            self.player = player
            self.sourceKey = sourceKey
            self.duration = resolvedDuration(hint: durationHint, fallback: player.duration)
            self.currentTime = 0
        } catch {
            self.player = nil
            self.sourceKey = nil
            self.duration = resolvedDuration(hint: durationHint, fallback: 0)
            self.currentTime = 0
        }
    }

    func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            pause()
            return
        }

        configurePlaybackSession()
        player.enableRate = true
        player.rate = rate.rawValue
        player.play()
        isPlaying = true
        startProgressPump()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        progressTask?.cancel()
        progressTask = nil
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
        currentTime = 0
        progressTask?.cancel()
        progressTask = nil
    }

    func seek(to progress: Double) {
        guard let player else { return }
        let clamped = min(max(progress, 0), 1)
        let nextTime = duration * clamped
        player.currentTime = nextTime
        currentTime = nextTime
    }

    func cycleRate() {
        rate = rate.next
    }

    private func startProgressPump() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let player = self.player {
                try? await Task.sleep(for: .milliseconds(33))
                self.currentTime = player.currentTime
                if !player.isPlaying {
                    self.isPlaying = false
                    if abs(player.currentTime - player.duration) < 0.05 {
                        self.currentTime = player.duration
                    }
                    self.progressTask?.cancel()
                    self.progressTask = nil
                    return
                }
            }
        }
    }

    private func configurePlaybackSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try? session.setActive(true)
        #endif
    }

    private func resolvedDuration(hint: TimeInterval?, fallback: TimeInterval) -> TimeInterval {
        if let hint, hint > 0.05 {
            return hint
        }
        return max(fallback, 0)
    }
}

enum VoiceNoteError: LocalizedError {
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone access is required to record voice messages."
        }
    }
}
