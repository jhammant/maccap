import Foundation
import SwiftUI

// Call assist: a helper program of your choice follows the call and shows
// cards in the live-notes window (who someone is, an answer to a question,
// something to watch). MacCap knows nothing about where the cards come from:
// it runs `assist_command`, writes the call to it as JSON lines on stdin and
// reads cards back from its stdout. The protocol is in the README.

enum AssistKind: String, Codable, CaseIterable {
    case brief, person, company, answer, watchout, commitment, question, screen, coach, note

    var label: String {
        switch self {
        case .brief: return "Brief"
        case .person: return "Person"
        case .company: return "Company"
        case .answer: return "Answer"
        case .watchout: return "Watch out"
        case .commitment: return "Promise"
        case .question: return "Question"
        case .screen: return "On screen"
        case .coach: return "Coach"
        case .note: return "Note"
        }
    }

    var symbol: String {
        switch self {
        case .brief: return "doc.text.fill"
        case .person: return "person.fill"
        case .company: return "building.2.fill"
        case .answer: return "lightbulb.fill"
        case .watchout: return "exclamationmark.triangle.fill"
        case .commitment: return "hand.raised.fill"
        case .question: return "questionmark.bubble.fill"
        case .screen: return "rectangle.on.rectangle"
        case .coach: return "speedometer"
        case .note: return "note.text"
        }
    }

    var color: Color {
        switch self {
        case .brief: return .teal
        case .person: return .blue
        case .company: return .indigo
        case .answer: return .green
        case .watchout: return .orange
        case .commitment: return .purple
        case .question: return .pink
        case .screen: return .cyan
        case .coach: return .mint
        case .note: return .gray
        }
    }

    /// Unknown kinds from a newer helper show as notes rather than failing.
    init(from decoder: Decoder) throws {
        self = AssistKind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .note
    }
}

struct AssistCard: Codable, Identifiable, Equatable {
    enum State: String, Codable { case looking, ready, failed }

    var id: String
    var kind: AssistKind
    var title: String
    var chips: [String]?
    /// The words on the call (or on screen) that brought it up.
    var quote: String?
    /// What was found.
    var body: String?
    /// Where it came from, in a few words.
    var source: String?
    /// Seconds from the start of the recording.
    var at: Double?
    var state: State?
    /// Kept at the top (the meeting brief, answers you asked for).
    var pinned: Bool?
    /// A button on the card: "next_call" saves this call and starts the next.
    var action: String?
    /// More, shown when the card is clicked open.
    var detail: String?
    /// Opened by the card's Open button (a brief, a CRM record, a wiki page).
    var link: String?
    /// A follow-up: the answer whose thread it is in (the thread's first card).
    var parent: String?

    var isLooking: Bool { state == .looking }
}

final class AssistViewModel: ObservableObject {
    @Published var cards: [AssistCard] = []
    @Published var title: String?
    @Published var workspace: String?
    @Published var status = ""
    /// A helper program is running (the help bar works).
    @Published var running = false
    @Published var talk = TalkStats()
    /// You are saying an action (Control-Option-A until pressed again).
    @Published var aside = false
    /// The card a click on the map asked for: opened and scrolled to.
    @Published var focused: String?
    /// Meetings the helper could be working from (it picked `chosen`).
    @Published var choices: [AssistChoice] = []
    @Published var chosen: String?
    /// The card to outline: the newest answer to a help request.
    @Published var highlighted: String?
    /// Help requests not answered yet, by card id.
    @Published var waiting: Set<String> = []

    /// Pinned first (newest first), then the rest newest first. Follow-ups
    /// are shown inside their thread's first card, not on their own.
    var ordered: [AssistCard] {
        let ids = Set(cards.map(\.id))
        let roots = cards.filter { $0.parent.map { !ids.contains($0) } ?? true }
        let pinned = roots.filter { $0.pinned == true }.reversed()
        let rest = roots.filter { $0.pinned != true }.reversed()
        return Array(pinned) + Array(rest)
    }

    /// The follow-ups to an answer, oldest first.
    func thread(_ id: String) -> [AssistCard] {
        cards.filter { $0.parent == id }
    }

    /// An answer and its follow-ups as questions and answers, oldest first:
    /// what a follow-up to it needs to make sense ("and the second point?").
    func conversation(_ id: String) -> [[String: String]] {
        guard let root = cards.first(where: { $0.id == id }) else { return [] }
        return ([root] + thread(id)).compactMap { card in
            guard !card.isLooking, let answer = card.body, !answer.isEmpty else { return nil }
            let about = card.quote.map { " (about “\($0)”)" } ?? ""
            return ["question": card.title + about, "answer": answer]
        }
    }

    /// A card and its follow-ups.
    func remove(_ id: String) {
        cards.removeAll { $0.id == id || $0.parent == id }
    }

    func upsert(_ card: AssistCard) {
        let old = cards.firstIndex { $0.id == card.id }
        if waiting.contains(card.id), !card.isLooking {
            waiting.remove(card.id)
            highlighted = card.parent ?? old.flatMap { cards[$0].parent } ?? card.id
        }
        if let index = old {
            // A reply keeps what its placeholder knew (when, the words, its thread).
            var card = card
            card.at = card.at ?? cards[index].at
            card.quote = card.quote ?? cards[index].quote
            card.parent = card.parent ?? cards[index].parent
            cards[index] = card
        } else {
            cards.append(card)
            if cards.count > 80, let drop = cards.firstIndex(where: { $0.pinned != true }) { cards.remove(at: drop) }
        }
    }
}

struct AssistChoice: Identifiable, Equatable {
    let id: String
    let label: String
}

/// One message from the helper, decoded leniently: anything it can't read is
/// logged and skipped.
enum AssistMessage {
    case card(AssistCard)
    case remove(String)
    case status(String)
    case context(title: String?, workspace: String?)
    case speaker(stem: LiveStem, start: Double, end: Double, name: String)
    case choices([AssistChoice], selected: String?)

    static func decode(_ line: Data) -> AssistMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "card":
            return (try? JSONDecoder().decode(AssistCard.self, from: line)).map { .card($0) }
        case "remove":
            return (object["id"] as? String).map { .remove($0) }
        case "status":
            return (object["text"] as? String).map { .status($0) }
        case "context":
            return .context(title: object["title"] as? String, workspace: object["workspace"] as? String)
        case "choices":
            let options = (object["options"] as? [[String: Any]] ?? []).compactMap { option -> AssistChoice? in
                guard let id = option["id"] as? String, let label = option["label"] as? String else { return nil }
                return AssistChoice(id: id, label: label)
            }
            return .choices(options, selected: object["selected"] as? String)
        case "speaker":
            guard let start = object["start"] as? Double, let end = object["end"] as? Double,
                  let name = object["name"] as? String else { return nil }
            let stem = LiveStem(rawValue: object["stem"] as? String ?? "system") ?? .system
            return .speaker(stem: stem, start: start, end: end, name: name)
        default:
            return nil
        }
    }
}

/// Runs the helper program for one call. Its stderr goes to MacCap's log.
/// If it can't start or stops, the call is recorded as normal.
final class AssistClient {
    var onMessage: ((AssistMessage) -> Void)?
    var onExit: ((Int32) -> Void)?

    private let command: [String]
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let writer = DispatchQueue(label: "maccap.assist.write")
    private var pending = Data()
    private var errorText = Data()
    private var stopped = false

    init(command: [String]) {
        self.command = command
    }

    func start(environment extra: [String: String] = [:]) throws {
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.environment = ProcessInfo.processInfo.environment.merging(extra) { _, new in new }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // A helper that dies must not take MacCap with it: writing to its
        // closed stdin fails with an error instead of SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.read(handle.availableData)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.readErrors(handle.availableData)
        }
        process.terminationHandler = { [weak self] process in
            self?.output.fileHandleForReading.readabilityHandler = nil
            self?.errors.fileHandleForReading.readabilityHandler = nil
            let status = process.terminationStatus
            Log.shared.write("assist: helper exited (\(status))")
            DispatchQueue.main.async { self?.onExit?(status) }
        }
        try process.run()
        Log.shared.write("assist: started \(command[0])")
    }

    func send(_ event: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: event, options: [.withoutEscapingSlashes]) else {
            return
        }
        data.append(0x0A)
        writer.async { [input] in
            guard !self.stopped else { return }
            do {
                try input.fileHandleForWriting.write(contentsOf: data)
            } catch {
                self.stopped = true
                Log.shared.write("assist: helper is not reading (\(error))")
            }
        }
    }

    /// Says the call has ended and closes its stdin; the helper gets `grace`
    /// seconds to finish before it is stopped.
    func stop(grace: Double = 5) {
        send(["type": "end"])
        writer.async { [input] in
            self.stopped = true
            try? input.fileHandleForWriting.close()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [process] in
            if process.isRunning { process.terminate() }
        }
    }

    private func read(_ data: Data) {
        guard !data.isEmpty else { return }
        pending.append(data)
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            guard !line.isEmpty else { continue }
            if let message = AssistMessage.decode(Data(line)) {
                DispatchQueue.main.async { self.onMessage?(message) }
            } else {
                Log.shared.write("assist: skipped a line it could not read: \(String(decoding: line.prefix(200), as: UTF8.self))")
            }
        }
        if pending.count > 1_000_000 { pending.removeAll() }
    }

    private func readErrors(_ data: Data) {
        guard !data.isEmpty else { return }
        errorText.append(data)
        while let newline = errorText.firstIndex(of: 0x0A) {
            let line = String(decoding: errorText[errorText.startIndex..<newline], as: UTF8.self)
            errorText.removeSubrange(errorText.startIndex...newline)
            if !line.isEmpty { Log.shared.write("assist: \(line.prefix(500))") }
        }
    }
}
