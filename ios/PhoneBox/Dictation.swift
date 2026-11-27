import AVFoundation
import Speech

/// The Dictation widget's speech recognizer: Apple's SFSpeechRecognizer in place of Android's SpeechRecognizer
/// (Dictation.kt), with the same contract for the panel. Each session has an id (chosen by the bridge shim, which must
/// answer listen() synchronously); events go to the panel's main frame as window.onAndroidSpeech(kind, text, id) with
/// kind ready / partial / end / final / error, and stop or cancel act only on the session they name. Error texts are
/// the ones widgets/dictate.js knows: permission, permission-blocked, unavailable, offline-unavailable, cancelled,
/// "7" (nothing heard) and "2" (network). The microphone is open at most a minute; nothing is stored.
@MainActor
final class Dictation {
    private static let maxDuration: TimeInterval = 60
    private static let maxChars = 2000
    /// Android's recognizer ends by itself when the speaker stops; Apple's keeps listening, so this much quiet after
    /// some words ends the session.
    private static let quietAfterSpeech: TimeInterval = 2

    private let send: (String) -> Void
    private var session = 0
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var limitTimer: Timer?
    private var quietTimer: Timer?
    private var lastText = ""

    init(send: @escaping (String) -> Void) { self.send = send }

    /// For the bridge snapshot (canListen): a recognizer exists for the iPad's language and nothing was refused.
    var available: Bool {
        let speech = SFSpeechRecognizer.authorizationStatus()
        let mic = AVAudioApplication.shared.recordPermission
        return SFSpeechRecognizer() != nil && speech != .denied && speech != .restricted && mic != .denied
    }

    /// Starts session [id] ([lang] a BCP 47 tag or "" for the iPad's language); a running session is cancelled.
    func start(id: Int, lang: String, offline: Bool) {
        if session != 0 { let was = session; end(); emit("error", "cancelled", was) }
        session = id
        Task { await self.begin(id: id, lang: lang, offline: offline) }
    }

    /// Stops listening and delivers what was heard so far, if [id] is the session running.
    func stop(id: Int) {
        guard id == session, request != nil else { return }
        finishListening()
    }

    /// Drops the session without a result, if [id] is the one running. 0 = whatever runs (the panel was hidden).
    func cancel(id: Int) {
        guard session != 0, id == 0 || id == session else { return }
        let was = session
        end()
        emit("error", "cancelled", was)
    }

    private func begin(id: Int, lang: String, offline: Bool) async {
        guard await permitted(id: id), id == session else { return }
        let tag = String(lang.prefix(20).filter { $0.isLetter || $0.isNumber || $0 == "-" })
        guard let recognizer = tag.isEmpty ? SFSpeechRecognizer() : SFSpeechRecognizer(locale: Locale(identifier: tag)),
              recognizer.isAvailable else { fail(id, "unavailable"); return }
        // "on this device only" is a promise: refuse rather than send the audio to Apple's servers
        if offline && !recognizer.supportsOnDeviceRecognition { fail(id, "offline-unavailable"); return }

        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audio.setActive(true, options: .notifyOthersOnDeactivation)
        } catch { fail(id, "unavailable"); return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        if offline { request.requiresOnDeviceRecognition = true }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { fail(id, "unavailable"); return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); fail(id, "unavailable"); return }

        self.engine = engine
        self.request = request
        lastText = ""
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failure = error.map { Self.code(for: $0 as NSError) }
            Task { @MainActor in self?.handle(id: id, text: text, isFinal: isFinal, failure: failure) }
        }
        limitTimer = Timer.scheduledTimer(withTimeInterval: Self.maxDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { if self?.session == id { self?.finishListening() } }
        }
        emit("ready", "", id)
    }

    private func handle(id: Int, text: String?, isFinal: Bool, failure: String?) {
        guard id == session else { return }
        if let text, !text.isEmpty { lastText = text }
        if isFinal {
            end()
            emit("final", lastText, id)
        } else if let failure {
            end()
            // ended by stop() with words already heard: that is the result, not an error
            if !lastText.isEmpty { emit("final", lastText, id) } else { emit("error", failure, id) }
        } else if let text, !text.isEmpty {
            emit("partial", text, id)
            quietTimer?.invalidate()
            quietTimer = Timer.scheduledTimer(withTimeInterval: Self.quietAfterSpeech, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { if self?.session == id { self?.finishListening() } }
            }
        }
    }

    /// No more audio: the recognizer then delivers its final result.
    private func finishListening() {
        guard let request else { return }
        quietTimer?.invalidate(); quietTimer = nil
        limitTimer?.invalidate(); limitTimer = nil
        stopAudio()
        request.endAudio()
        self.request = nil
        emit("end", "", session)
    }

    private func stopAudio() {
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func end() {
        quietTimer?.invalidate(); quietTimer = nil
        limitTimer?.invalidate(); limitTimer = nil
        stopAudio()
        task?.cancel()
        task = nil
        request = nil
        session = 0
    }

    private func fail(_ id: Int, _ code: String) {
        if id == session { end() }
        emit("error", code, id)
    }

    /// Both prompts (speech recognition, then the microphone) on first use. A refusal is final: only Settings › Apps ›
    /// PhoneBox can turn either back on, which is what "permission-blocked" tells the user.
    private func permitted(id: Int) async -> Bool {
        var speech = SFSpeechRecognizer.authorizationStatus()
        if speech == .notDetermined {
            speech = await withCheckedContinuation { done in SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) } }
        }
        guard speech == .authorized else { fail(id, speech == .denied ? "permission-blocked" : "unavailable"); return false }
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: fail(id, "permission-blocked"); return false
        default:
            if await AVAudioApplication.requestRecordPermission() { return true }
            fail(id, "permission-blocked")
            return false
        }
    }

    /// Apple's errors in the panel's words: nothing heard, or the recognizer could not be reached.
    private nonisolated static func code(for error: NSError) -> String {
        if error.domain == "kAFAssistantErrorDomain" && [1110, 203].contains(error.code) { return "7" } // no speech detected
        if error.domain == "kLSRErrorDomain" && error.code == 301 { return "cancelled" }
        return "2"
    }

    private func emit(_ kind: String, _ text: String, _ id: Int) {
        guard id > 0 else { return }
        send("window.onAndroidSpeech && window.onAndroidSpeech(\(Bridge.jsString(kind)), \(Bridge.jsString(String(text.prefix(Self.maxChars)))), \(id))")
    }
}
