import Foundation
import AVFoundation
import Speech

// MARK: - Recording

/// Records a voice memo, sampling the input level as it goes so the memo can be
/// drawn as a waveform afterwards.
@MainActor
@Observable
final class VoiceMemoRecorder {
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    /// Levels captured so far, for the live waveform.
    private(set) var levels: [Float] = []

    private var recorder: AVAudioRecorder?
    private var fileName: String?
    private var meterTask: Task<Void, Never>?

    /// How many bars a saved memo keeps, regardless of its length.
    private static let waveformResolution = 44
    private static let sampleInterval: Duration = .milliseconds(50)

    var formattedElapsed: String {
        Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond))
    }

    /// Asks for microphone access and starts recording into the attachments
    /// directory. Returns false when permission is refused.
    func start() async -> Bool {
        guard await AVAudioApplication.requestRecordPermission() else { return false }

        let fileName = "\(UUID().uuidString).m4a"
        guard let url = AttachmentStore.url(forFileName: fileName) else { return false }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)

            let recorder = try AVAudioRecorder(
                url: url,
                settings: [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: 44_100.0,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                ]
            )
            recorder.isMeteringEnabled = true
            recorder.record()

            self.recorder = recorder
            self.fileName = fileName
            isRecording = true
            elapsed = 0
            levels = []
            startMetering()
            return true
        } catch {
            print("Wispr: could not start recording — \(error)")
            return false
        }
    }

    /// Stops recording and describes the memo, or returns nil if nothing usable
    /// was captured.
    func finish() -> NoteAttachment? {
        guard let recorder, let fileName else { return nil }
        stopMetering()

        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        self.fileName = nil
        isRecording = false

        guard let url = AttachmentStore.url(forFileName: fileName) else { return nil }

        // Too short to be worth keeping.
        guard duration > 0.3 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return NoteAttachment(
            kind: .audio,
            fileName: fileName,
            displayName: "Voice memo",
            byteCount: attributes?[.size] as? Int ?? 0,
            duration: duration,
            waveform: Self.downsample(levels, to: Self.waveformResolution)
        )
    }

    /// Throws the recording away, file and all.
    func cancel() {
        guard let recorder, let fileName else { return }
        stopMetering()
        recorder.stop()
        self.recorder = nil
        self.fileName = nil
        isRecording = false

        if let url = AttachmentStore.url(forFileName: fileName) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: Metering

    private func startMetering() {
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.sampleInterval)
                guard let self, let recorder = self.recorder, recorder.isRecording else { return }

                recorder.updateMeters()
                self.levels.append(Self.normalize(recorder.averagePower(forChannel: 0)))
                self.elapsed = recorder.currentTime
            }
        }
    }

    private func stopMetering() {
        meterTask?.cancel()
        meterTask = nil
    }

    /// Maps decibels onto 0...1, treating anything under -50 dB as silence.
    private static func normalize(_ decibels: Float) -> Float {
        guard decibels.isFinite else { return 0 }
        return min(max((decibels + 50) / 50, 0), 1)
    }

    /// Averages the captured levels down to a fixed number of bars.
    private static func downsample(_ levels: [Float], to count: Int) -> [Float] {
        guard levels.count > count else { return levels }

        let bucketSize = Double(levels.count) / Double(count)
        return (0..<count).map { index in
            let start = Int(Double(index) * bucketSize)
            let end = min(Int(Double(index + 1) * bucketSize), levels.count)
            guard start < end else { return levels[min(start, levels.count - 1)] }
            return levels[start..<end].reduce(0, +) / Float(end - start)
        }
    }
}

// MARK: - Playback

/// Plays one voice memo at a time, wherever it was tapped from.
@MainActor
@Observable
final class VoiceMemoPlayer {
    static let shared = VoiceMemoPlayer()

    private(set) var currentID: UUID?
    private(set) var isPlaying = false
    /// How far through the current memo playback is, 0...1.
    private(set) var progress: Double = 0
    private(set) var elapsed: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var progressTask: Task<Void, Never>?
    private var delegate: PlaybackDelegate?

    func isCurrent(_ attachment: NoteAttachment) -> Bool {
        currentID == attachment.id
    }

    func isPlaying(_ attachment: NoteAttachment) -> Bool {
        isCurrent(attachment) && isPlaying
    }

    func progress(for attachment: NoteAttachment) -> Double {
        isCurrent(attachment) ? progress : 0
    }

    /// The time to show next to a memo: how far into it playback is, or its length.
    func displayedTime(for attachment: NoteAttachment) -> TimeInterval {
        isCurrent(attachment) ? elapsed : attachment.duration
    }

    func toggle(_ attachment: NoteAttachment) {
        if isPlaying(attachment) {
            pause()
        } else {
            play(attachment)
        }
    }

    func play(_ attachment: NoteAttachment) {
        if isCurrent(attachment), let player {
            startProgressUpdates()
            player.play()
            isPlaying = true
            return
        }

        guard let url = attachment.url else { return }
        stop()

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)

            let player = try AVAudioPlayer(contentsOf: url)
            let delegate = PlaybackDelegate { [weak self] in self?.finish() }
            player.delegate = delegate
            player.play()

            self.player = player
            self.delegate = delegate
            currentID = attachment.id
            isPlaying = true
            progress = 0
            elapsed = 0
            startProgressUpdates()
        } catch {
            print("Wispr: could not play memo — \(error)")
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopProgressUpdates()
    }

    /// Back to the start, staying paused.
    func reset(_ attachment: NoteAttachment) {
        guard isCurrent(attachment) else {
            progress = 0
            elapsed = 0
            return
        }
        player?.pause()
        player?.currentTime = 0
        isPlaying = false
        progress = 0
        elapsed = 0
        stopProgressUpdates()
    }

    func stop() {
        stopProgressUpdates()
        player?.stop()
        player = nil
        delegate = nil
        currentID = nil
        isPlaying = false
        progress = 0
        elapsed = 0
    }

    private func finish() {
        stopProgressUpdates()
        player?.currentTime = 0
        isPlaying = false
        progress = 0
        elapsed = 0
    }

    private func startProgressUpdates() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, let player = self.player, player.isPlaying else { return }
                self.elapsed = player.currentTime
                self.progress = player.duration > 0 ? player.currentTime / player.duration : 0
            }
        }
    }

    private func stopProgressUpdates() {
        progressTask?.cancel()
        progressTask = nil
    }

    private final class PlaybackDelegate: NSObject, AVAudioPlayerDelegate {
        private let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            Task { @MainActor in onFinish() }
        }
    }
}

// MARK: - Transcription

/// Turns a recorded memo into text with the on-device speech transcriber.
enum VoiceMemoTranscriber {
    enum Failure: LocalizedError {
        case languageUnavailable
        case noSpeechFound

        var errorDescription: String? {
            switch self {
            case .languageUnavailable:
                "Transcription isn't available for this language on this device."
            case .noSpeechFound:
                "No speech was found in this memo."
            }
        }
    }

    static func transcript(of attachment: NoteAttachment) async throws -> String {
        guard let url = attachment.url else { throw Failure.noSpeechFound }
        var locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current)
        if locale == nil {
            locale = await SpeechTranscriber.supportedLocales.first
        }
        guard let locale else { throw Failure.languageUnavailable }

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: url)

        // Results arrive as the file is analyzed, so collect them alongside.
        let collected = Task {
            var text = AttributedString()
            for try await result in transcriber.results {
                text += result.text
            }
            return String(text.characters)
        }

        if let lastSample = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        let transcript = try await collected.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { throw Failure.noSpeechFound }
        return transcript
    }
}
