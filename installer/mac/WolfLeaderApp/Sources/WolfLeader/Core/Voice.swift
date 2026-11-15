import AVFoundation
import Speech
import SwiftUI

/// Talk to type: the Mac's own speech recognition, so it works the same with every AI.
/// One box listens at a time. Words go to that box as they are heard.
@MainActor
final class Dictation: ObservableObject {
    static let shared = Dictation()

    @Published private(set) var listening = false
    @Published private(set) var owner: String?
    @Published var error: String?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onText: ((String) -> Void)?
    /// Goes up with every start, so a late callback from an earlier session is ignored.
    private var run = 0

    func isListening(_ id: String) -> Bool { listening && owner == id }

    /// Start listening for this box, or stop if it already is.
    func toggle(id: String, onText: @escaping (String) -> Void) {
        if isListening(id) {
            stop()
        } else {
            Task { await start(id: id, onText: onText) }
        }
    }

    func stop() {
        run += 1
        onText = nil
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        listening = false
        owner = nil
    }

    private func start(id: String, onText: @escaping (String) -> Void) async {
        stop()
        error = nil
        Speaker.shared.stop()
        guard await Self.speechAllowed() else {
            error = "Turn on Speech Recognition for Wolf Leader in System Settings > Privacy & Security."
            return
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            error = "Turn on the Microphone for Wolf Leader in System Settings > Privacy & Security."
            return
        }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            error = "Speech recognition isn't available for this Mac's language right now."
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        // On the Mac itself when it can: private, no time limit, works offline.
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        run += 1
        let thisRun = run
        do {
            try Self.feed(engine, into: request)
        } catch {
            self.error = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }
        self.request = request
        self.onText = onText
        owner = id
        listening = true
        task = Self.recognize(recognizer, request) { [weak self] text, ended in
            Task { @MainActor in
                guard let self, self.run == thisRun else { return }
                if let text { self.onText?(text) }
                if ended { self.stop() }
            }
        }
    }

    // These run their callbacks on background threads, so they must not be tied to the main actor.

    private nonisolated static func speechAllowed() async -> Bool {
        await withCheckedContinuation { done in
            SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0 == .authorized) }
        }
    }

    private nonisolated static func feed(_ engine: AVAudioEngine, into request: SFSpeechAudioBufferRecognitionRequest) throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        nonisolated(unsafe) let request = request
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private nonisolated static func recognize(_ recognizer: SFSpeechRecognizer, _ request: SFSpeechAudioBufferRecognitionRequest,
                                              heard: @escaping @Sendable (String?, Bool) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            heard(result?.bestTranscription.formattedString, error != nil || (result?.isFinal ?? false))
        }
    }
}

/// Reads replies aloud with the Mac's own voice.
@MainActor
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()
    private static let key = "wl.voice.readAloud"

    /// Read each finished reply in the chat that's on screen.
    @Published var readAloud = UserDefaults.standard.bool(forKey: Speaker.key) {
        didSet {
            UserDefaults.standard.set(readAloud, forKey: Self.key)
            if !readAloud { stop() }
        }
    }
    @Published private(set) var speaking = false
    /// The chat on screen; replies in other chats stay quiet.
    var activeChatID: String?

    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// A reply finished. Read it if reading is on and that chat is the one being looked at.
    func replyFinished(chatID: String, text: String) {
        guard readAloud, chatID == activeChatID, !Dictation.shared.listening else { return }
        speak(text)
    }

    func speak(_ text: String) {
        let plain = Self.speakable(text)
        guard !plain.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: plain)
        utterance.voice = Self.bestVoice()
        synthesizer.speak(utterance)
        speaking = true
    }

    func stop() {
        guard synthesizer.isSpeaking else { speaking = false; return }
        synthesizer.stopSpeaking(at: .immediate)
        speaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = self.synthesizer.isSpeaking }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = self.synthesizer.isSpeaking }
    }

    /// The best voice installed for the Mac's language (a downloaded Premium or Enhanced one if there is one).
    private static func bestVoice() -> AVSpeechSynthesisVoice? {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let prefix = String(language.prefix(2))
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }
        let ranked = voices.sorted {
            ($0.quality.rawValue, $0.language == language ? 1 : 0) > ($1.quality.rawValue, $1.language == language ? 1 : 0)
        }
        return ranked.first ?? AVSpeechSynthesisVoice(language: language)
    }

    /// What's worth saying out loud: the prose, without code, tables, links or markdown marks.
    static func speakable(_ markdown: String) -> String {
        var text = markdown
        func replace(_ pattern: String, _ with: String, _ options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: with)
        }
        replace("```[\\s\\S]*?```", " (code shown on screen) ")
        replace("^\\s*\\|.*\\|\\s*$", "", [.anchorsMatchLines])          // table rows
        replace("!?\\[([^\\]]*)\\]\\([^)]*\\)", "$1")                     // links: keep the words
        replace("https?://\\S+", "a link")
        replace("`([^`]*)`", "$1")
        replace("^\\s{0,3}#{1,6}\\s*", "", [.anchorsMatchLines])
        replace("^\\s*[-*•]\\s+", "", [.anchorsMatchLines])
        replace("[*_~]{1,3}", "")
        replace("\\n{2,}", ".\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The microphone button next to a message box. Click to talk, click again to stop.
struct MicButton: View {
    @Environment(\.palette) private var p
    @ObservedObject private var dictation = Dictation.shared
    /// Which box this is, so only one listens at a time.
    let id: String
    @Binding var draft: String
    @State private var pulse = false

    var body: some View {
        let on = dictation.isListening(id)
        Button {
            let base = draft
            let gap = base.isEmpty || base.hasSuffix(" ") || base.hasSuffix("\n") ? "" : " "
            dictation.toggle(id: id) { heard in draft = base + gap + heard }
        } label: {
            Image(systemName: on ? "mic.fill" : "mic")
                .foregroundStyle(on ? p.bad : p.textMuted)
                .opacity(on && pulse ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .help(on ? "Listening. Click to stop." : (dictation.error ?? "Talk instead of typing"))
        .onChange(of: on) { _, listening in
            if listening {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
            } else {
                withAnimation(.default) { pulse = false }
            }
        }
        .popover(isPresented: Binding(get: { dictation.error != nil && !on }, set: { if !$0 { dictation.error = nil } })) {
            Text(dictation.error ?? "").font(DS.Font.caption).padding(12).frame(maxWidth: 280)
        }
    }
}

/// Turns reading replies aloud on and off; while a reply is being read, it stops it.
struct ReadAloudButton: View {
    @Environment(\.palette) private var p
    @ObservedObject private var speaker = Speaker.shared

    var body: some View {
        Button {
            if speaker.speaking { speaker.stop() } else { speaker.readAloud.toggle() }
        } label: {
            Image(systemName: speaker.speaking ? "stop.circle.fill" : (speaker.readAloud ? "speaker.wave.2.fill" : "speaker.slash"))
                .foregroundStyle(speaker.readAloud || speaker.speaking ? p.accent : p.textMuted)
        }
        .buttonStyle(.plain)
        .help(speaker.speaking ? "Stop reading" : (speaker.readAloud ? "Replies are read aloud. Click to turn off." : "Read replies aloud"))
    }
}
