import Foundation
import Speech
import AVFoundation

/// Thin wrapper over `SFSpeechRecognizer`. Navigation must keep working when
/// speech is unavailable, so every failure is reported rather than thrown.
@Observable
final class SpeechListener {
    private(set) var transcript = ""
    private(set) var isListening = false
    private(set) var errorMessage: String?
    private(set) var isAuthorized = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    func requestAuthorization() async {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        let mic = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        await MainActor.run {
            isAuthorized = (speech == .authorized) && mic
            if !isAuthorized {
                errorMessage = "Speech recognition needs microphone and speech permission. You can still report problems by tapping."
            }
        }
    }

    @MainActor
    func start() {
        guard !isListening else { return }
        guard isAuthorized, let recognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognition is unavailable. Use the buttons to report a problem."
            return
        }

        transcript = ""
        errorMessage = nil

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            // Keep audio on device; this must work offline in an emergency.
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
            self.request = request

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
            isListening = true

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.stop()
                }
            }
        } catch {
            errorMessage = "Could not start listening: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isListening = false
        // Hand audio back so spoken guidance is not muted.
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .voicePrompt, options: [.duckOthers, .mixWithOthers]
        )
    }
}
