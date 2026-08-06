import Foundation
import AVFoundation
import UIKit

/// Spoken turn-by-turn plus turn/arrival haptics. Suppresses repeats so the
/// same instruction is not spoken on every frame.
final class Announcer {
    private let synthesizer = AVSpeechSynthesizer()
    private var lastSpoken: String?
    private var lastSpokenAt: Date = .distantPast
    private let impact = UIImpactFeedbackGenerator(style: .medium)
    private let success = UINotificationFeedbackGenerator()

    var isEnabled = true
    /// Do not repeat the same sentence more often than this.
    var repeatInterval: TimeInterval = 8

    init() {
        impact.prepare()
        success.prepare()
    }

    func configureAudioSession() {
        // Duck other audio rather than stopping it; guidance is short.
        try? AVAudioSession.sharedInstance().setCategory(
            .playback, mode: .voicePrompt, options: [.duckOthers, .mixWithOthers]
        )
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func say(_ text: String, force: Bool = false) {
        guard isEnabled, !text.isEmpty else { return }
        let now = Date()
        if !force, text == lastSpoken, now.timeIntervalSince(lastSpokenAt) < repeatInterval { return }
        lastSpoken = text
        lastSpokenAt = now

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
    }

    /// Distinct haptic patterns so events are distinguishable without looking.
    enum Cue {
        case routeStarted, approachingTurn, turnNow, routeChanged, destination, trackingLost
    }

    func haptic(_ cue: Cue) {
        guard isEnabled else { return }
        switch cue {
        case .routeStarted:
            success.notificationOccurred(.success)
        case .approachingTurn:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .turnNow:
            impact.impactOccurred()
        case .routeChanged:
            success.notificationOccurred(.warning)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                self?.impact.impactOccurred()
            }
        case .destination:
            success.notificationOccurred(.success)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.success.notificationOccurred(.success)
            }
        case .trackingLost:
            success.notificationOccurred(.error)
        }
    }

    func turnCue() { haptic(.turnNow) }

    func arrivalCue() { haptic(.destination) }

    /// Cuts off the current utterance without tearing down the audio session.
    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        lastSpoken = nil
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
