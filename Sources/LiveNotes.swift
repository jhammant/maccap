import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// Live notes during a call: the transcript so far (You = the mic, Them = the
// call side) and rolling notes from a language model. The pure parts live
// here so the self-tests can check them; Speech is in LiveTranscriber.swift
// and the window in Overlay.swift.

enum LiveStem: String, Codable {
    case mic, system

    var speaker: String { self == .mic ? "You" : "Them" }
}

struct LiveLine: Equatable {
    var stem: LiveStem
    var start: Double  // seconds from the start of the recording
    var end: Double
    var text: String
    /// Who said it, when the assist recognised the voice (else You / Them).
    var name: String? = nil

    var label: String { name ?? stem.speaker }
}

/// The final transcript lines of both sides, in time order. A speakerphone
/// lets the call side leak into the mic, so the mic's transcriber hears the
/// other side too: a mic line that repeats a call-side line from the same
/// moment is echo and is dropped, whichever of the two arrives first.
struct LiveTranscript {
    static let echoWindow = 2.5
    static let echoSimilarity = 0.6

    private(set) var lines: [LiveLine] = []
    private(set) var echoDropped = 0
    /// Lines in progress (not final yet), one per side.
    var volatile: [LiveStem: LiveLine] = [:]
    /// Who was speaking when, from the assist's live speaker labels.
    private(set) var spans: [SpeakerSpan] = []

    struct SpeakerSpan: Equatable {
        var stem: LiveStem
        var start: Double
        var end: Double
        var name: String
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'") }.map(String.init)
    }

    /// Share of shared words (Jaccard), 0...1.
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Set(words(a)), y = Set(words(b))
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    /// Share of `part`'s words that are also in `whole`, 0...1.
    static func containment(_ part: String, in whole: String) -> Double {
        let x = Set(words(part)), y = Set(words(whole))
        guard !x.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(x.count)
    }

    /// A mic line is echo when it says the same as a call-side line from the
    /// same moment, or is a fragment of it (the transcribers split sentences
    /// in different places): two or more words, nearly all in the call line.
    static func isEcho(mic: LiveLine, of system: LiveLine) -> Bool {
        guard abs(mic.start - system.start) <= echoWindow else { return false }
        if similarity(mic.text, system.text) >= echoSimilarity { return true }
        return words(mic.text).count >= 2 && containment(mic.text, in: system.text) >= 0.8
    }

    mutating func add(_ line: LiveLine) {
        volatile[line.stem] = nil
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var line = line
        line.text = text
        switch line.stem {
        case .mic:
            if lines.contains(where: { $0.stem == .system && Self.isEcho(mic: line, of: $0) }) {
                echoDropped += 1
                return
            }
        case .system:
            let before = lines.count
            lines.removeAll { $0.stem == .mic && Self.isEcho(mic: $0, of: line) }
            echoDropped += before - lines.count
        }
        line.name = Self.name(for: line, in: spans)
        let index = lines.firstIndex { $0.start > line.start } ?? lines.endIndex
        lines.insert(line, at: index)
    }

    /// Records who was speaking on one side from `start` to `end`, and names
    /// the lines already there that it covers.
    mutating func nameSpeaker(_ span: SpeakerSpan) {
        spans.append(span)
        if spans.count > 4000 { spans.removeFirst(1000) }
        for i in lines.indices where lines[i].stem == span.stem && lines[i].end > span.start && lines[i].start < span.end {
            lines[i].name = Self.name(for: lines[i], in: spans) ?? lines[i].name
        }
    }

    /// The name that covers most of the line, if it covers at least a third.
    static func name(for line: LiveLine, in spans: [SpeakerSpan]) -> String? {
        var covered: [String: Double] = [:]
        for span in spans where span.stem == line.stem {
            let overlap = min(span.end, line.end) - max(span.start, line.start)
            if overlap > 0 { covered[span.name, default: 0] += overlap }
        }
        guard let best = covered.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) })
        else { return nil }
        return best.value >= max(0.1, line.end - line.start) / 3 ? best.key : nil
    }

    /// The mic's line in progress, unless it is the call side's echo. A line
    /// in progress is only part of a sentence, so it counts as echo when most
    /// of its words are in what the call side said at the same moment.
    func shownVolatile(_ stem: LiveStem) -> LiveLine? {
        guard let line = volatile[stem] else { return nil }
        if stem == .mic {
            let heard = lines.suffix(6).filter { $0.stem == .system } + [volatile[.system]].compactMap { $0 }
            if heard.contains(where: {
                abs(line.start - $0.start) <= Self.echoWindow
                    && Self.containment(line.text, in: $0.text) >= Self.echoSimilarity
            }) { return nil }
        }
        return line
    }

    static func stamp(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// Plain text, newest last, at most `maxWords` words (older lines are left
    /// out first).
    func text(maxWords: Int = .max) -> String {
        var out: [String] = []
        var count = 0
        for line in lines.reversed() {
            count += Self.words(line.text).count
            if count > maxWords, !out.isEmpty { break }
            out.append("[\(Self.stamp(line.start))] \(line.label): \(line.text)")
        }
        return out.reversed().joined(separator: "\n")
    }
}

/// Notes in three parts. The model is asked for exactly these headings; a
/// reply that ignores them is kept whole as key points.
struct LiveNotesSections: Equatable {
    var keyPoints: [String] = []
    var questions: [String] = []
    var actions: [String] = []

    var isEmpty: Bool { keyPoints.isEmpty && questions.isEmpty && actions.isEmpty }

    static func parse(_ reply: String) -> LiveNotesSections {
        var notes = LiveNotesSections()
        var current: WritableKeyPath<LiveNotesSections, [String]>? = nil
        var loose: [String] = []
        for raw in reply.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let heading = line.uppercased().trimmingCharacters(in: CharacterSet(charactersIn: "#*: "))
            if heading.hasPrefix("KEY POINTS") { current = \.keyPoints; continue }
            if heading.hasPrefix("QUESTIONS") { current = \.questions; continue }
            if heading.hasPrefix("ACTIONS") { current = \.actions; continue }
            let item = line.trimmingCharacters(in: CharacterSet(charactersIn: "-*•· \t"))
            guard !item.isEmpty, item.lowercased() != "none" else { continue }
            if let current { notes[keyPath: current].append(item) } else { loose.append(item) }
        }
        if notes.isEmpty { notes.keyPoints = loose }
        return notes
    }

    /// Notes only ever grow during a call: a small model often leaves out
    /// items it wrote before, so each update is merged into what is there.
    /// An item that says nearly the same as an earlier one replaces it (the
    /// newer wording wins, e.g. a changed date); anything else is added.
    /// Key points keep the newest `maxKeyPoints`.
    static let maxKeyPoints = 15

    func merged(with fresh: LiveNotesSections) -> LiveNotesSections {
        func merge(_ old: [String], _ new: [String], cap: Int = .max) -> [String] {
            var out = old
            for item in new {
                if let index = out.firstIndex(where: { Self.sameItem($0, item) }) {
                    out[index] = item
                } else {
                    out.append(item)
                }
            }
            return Array(out.suffix(cap))
        }
        return LiveNotesSections(keyPoints: merge(keyPoints, fresh.keyPoints, cap: Self.maxKeyPoints),
                                 questions: merge(questions, fresh.questions),
                                 actions: merge(actions, fresh.actions))
    }

    /// Two items are the same when their meaningful words nearly match (a
    /// changed date still counts), or one says all of the other. When unsure
    /// both are kept: a repeat is better than a lost action.
    static func sameItem(_ a: String, _ b: String) -> Bool {
        let x = contentWords(a), y = contentWords(b)
        guard !x.isEmpty, !y.isEmpty else { return a.lowercased() == b.lowercased() }
        let shared = Double(x.intersection(y).count)
        if shared / Double(x.union(y).count) >= 0.6 { return true }
        return min(x.count, y.count) >= 3 && shared / Double(min(x.count, y.count)) >= 0.9
    }

    private static let filler: Set<String> = [
        "the", "a", "an", "to", "of", "by", "for", "and", "or", "on", "in", "at", "with", "about", "is", "are",
        "be", "will", "would", "should", "we", "you", "them", "they", "i", "it", "that", "this", "their", "our",
        "your", "has", "have", "can", "do", "does", "from", "as", "up",
    ]

    static func contentWords(_ text: String) -> Set<String> {
        Set(LiveTranscript.words(text).filter { !filler.contains($0) })
    }

    var markdown: String {
        func section(_ title: String, _ items: [String]) -> String {
            "## \(title)\n" + (items.isEmpty ? "- none\n" : items.map { "- \($0)\n" }.joined())
        }
        return section("Key points", keyPoints) + "\n" + section("Questions", questions) + "\n"
            + section("Actions", actions)
    }
}

enum LiveNotesPrompt {
    static let instructions = """
        You take notes for "You" during a live call. The transcript labels each line You (the user), \
        Them (someone else on the call) or the name of the person speaking. Reply in exactly this format, short bullets of a few \
        words, only what was actually said:
        KEY POINTS
        - ...
        QUESTIONS
        - (Them) or (You): the question
        ACTIONS
        - (You) or (Them): who promised what, with any date
        Write "- none" under a heading with nothing yet. No other text.
        """

    /// The request for one update: the notes so far plus the recent transcript.
    static func request(previous: LiveNotesSections?, transcript: String) -> String {
        var parts: [String] = []
        if let previous, !previous.isEmpty {
            parts.append("Notes so far (keep what is still right, add what is new):\n"
                + previous.markdown.replacingOccurrences(of: "## ", with: ""))
        }
        parts.append("Transcript (most recent part):\n\(transcript)")
        return parts.joined(separator: "\n\n")
    }

    /// Reasoning models put their thinking in <think>...</think>; only the
    /// answer after it is the notes.
    static func stripThinking(_ reply: String) -> String {
        guard let end = reply.range(of: "</think>") else { return reply }
        return String(reply[end.upperBound...])
    }
}

// MARK: Models

protocol LiveNotesModel {
    var name: String { get }
    /// Words of transcript one request can carry.
    var transcriptWords: Int { get }
    func notes(previous: LiveNotesSections?, transcript: String) async throws -> LiveNotesSections
    /// A short free-text answer (a marked moment's one line).
    func reply(instructions: String, text: String) async throws -> String
}

enum MomentPrompt {
    static let instructions = """
        The person using MacCap marked a moment in a live call. From the last lines of the transcript (You = that person), write ONE short \
        sentence: the action, decision or promise in them, saying who does what and by when if a time was said \
        (e.g. "You to send Alex the deck by Friday."). If there is no action, give the point in one sentence. \
        Reply with the sentence only.
        """
}

struct NotesModelError: Error, CustomStringConvertible {
    let description: String
}

/// Apple's on-device model (macOS 26+): free and private, with a small
/// context window, so it sees the most recent ~1,500 words.
@available(macOS 26.0, *)
struct AppleNotesModel: LiveNotesModel {
    let name = "Apple on-device"
    let transcriptWords = 1500

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    func notes(previous: LiveNotesSections?, transcript: String) async throws -> LiveNotesSections {
        #if canImport(FoundationModels)
        let session = LanguageModelSession(instructions: LiveNotesPrompt.instructions)
        let reply = try await session.respond(to: LiveNotesPrompt.request(previous: previous, transcript: transcript))
        return LiveNotesSections.parse(reply.content)
        #else
        throw NotesModelError(description: "FoundationModels is not available in this build")
        #endif
    }

    func reply(instructions: String, text: String) async throws -> String {
        #if canImport(FoundationModels)
        return try await LanguageModelSession(instructions: instructions).respond(to: text).content
        #else
        throw NotesModelError(description: "FoundationModels is not available in this build")
        #endif
    }
}

/// Any OpenAI-compatible chat endpoint: LM Studio or Ollama on this Mac, or a
/// hosted one. The API key, if needed, comes from an environment variable.
struct OpenAICompatibleNotesModel: LiveNotesModel {
    let url: URL
    let model: String
    let apiKeyEnv: String?
    let transcriptWords = 6000
    var name: String { "\(model) at \(url.host ?? url.absoluteString)" }

    func notes(previous: LiveNotesSections?, transcript: String) async throws -> LiveNotesSections {
        LiveNotesSections.parse(try await chat(system: LiveNotesPrompt.instructions,
                                               user: LiveNotesPrompt.request(previous: previous, transcript: transcript)))
    }

    func reply(instructions: String, text: String) async throws -> String {
        try await chat(system: instructions, user: text)
    }

    private func chat(system: String, user: String) async throws -> String {
        var request = URLRequest(url: url.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let env = apiKeyEnv, let key = ProcessInfo.processInfo.environment[env], !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        var body: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        if ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "") {
            // Local reasoning models (Qwen 3 in LM Studio) otherwise think for
            // minutes before every update; these switch that off. Hosted APIs
            // may reject them, so they are only sent to this Mac.
            body["chat_template_kwargs"] = ["enable_thinking": false]
            body["reasoning_effort"] = "none"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NotesModelError(description: "notes model at \(url.absoluteString) answered HTTP \(status)")
        }
        return LiveNotesPrompt.stripThinking(content).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The configured endpoint, with Apple's model answering any update it
/// can't (LM Studio not running, the model not loaded).
struct FallbackNotesModel: LiveNotesModel {
    let primary: LiveNotesModel
    let fallback: LiveNotesModel
    var name: String { primary.name }
    var transcriptWords: Int { primary.transcriptWords }

    func notes(previous: LiveNotesSections?, transcript: String) async throws -> LiveNotesSections {
        do {
            return try await primary.notes(previous: previous, transcript: transcript)
        } catch {
            Log.shared.write("live notes: \(primary.name) failed (\(error)); using \(fallback.name)")
            return try await fallback.notes(previous: previous,
                                            transcript: Self.lastWords(transcript, fallback.transcriptWords))
        }
    }

    func reply(instructions: String, text: String) async throws -> String {
        do {
            return try await primary.reply(instructions: instructions, text: text)
        } catch {
            return try await fallback.reply(instructions: instructions, text: text)
        }
    }

    /// The newest lines of a transcript, at most `count` words.
    static func lastWords(_ transcript: String, _ count: Int) -> String {
        var kept: [Substring] = []
        var words = 0
        for line in transcript.split(separator: "\n").reversed() {
            words += line.split(separator: " ").count
            if words > count, !kept.isEmpty { break }
            kept.append(line)
        }
        return kept.reversed().joined(separator: "\n")
    }
}

enum LiveNotesModels {
    /// The configured model (falling back to Apple's), else Apple's on-device one, else none.
    static func make(config: MacCapConfig) -> LiveNotesModel? {
        var apple: LiveNotesModel?
        if #available(macOS 26.0, *), AppleNotesModel.isAvailable { apple = AppleNotesModel() }
        if let raw = config.notesModelURL, let url = URL(string: raw) {
            let endpoint = OpenAICompatibleNotesModel(url: url, model: config.notesModel ?? "local-model",
                                                      apiKeyEnv: config.notesModelAPIKeyEnv)
            return apple.map { FallbackNotesModel(primary: endpoint, fallback: $0) } ?? endpoint
        }
        return apple
    }
}
