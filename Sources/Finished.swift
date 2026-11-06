import AppKit
import SwiftUI

// "Meeting finished": opens when a call with live notes is saved. Shows how
// the talking went and the next steps, ready to edit, and hands the ticked
// ones to `followup_command` (any program: a task runner, a to-do list, an
// email drafter) with one click. Without a command it is a recap you can copy.

struct MeetingSummary {
    var title: String?
    var startedAt: Date
    var duration: Double
    var apps: [String]
    var workspace: String?
    var notes: LiveNotesSections
    var talk: TalkStats
    var recording: URL
    var notesFile: URL?
    /// The whole call, "[mm:ss] Speaker: text" per line.
    var transcript = ""
    /// Actions you added during the call (typed, said, marked).
    var addedSteps: [(text: String, selected: Bool)] = []
    /// A final-notes command will rewrite the steps: start with your own only.
    var expectRewrite = false

    /// At most this many steps come from the live notes when nothing rewrites them.
    static let liveStepLimit = 4

    /// Without a rewrite: your own actions from the live notes, a few at most.
    var suggestedSteps: [String] {
        guard !expectRewrite else { return [] }
        let mine = notes.actions.filter { $0.hasPrefix("(You)") }
        return Array((mine.isEmpty ? notes.actions : mine).prefix(Self.liveStepLimit))
    }

    func payload(steps: [String]) -> [String: Any] {
        var talkJSON: [String: Any] = [
            "you_share": talk.yourShare, "your_questions": talk.yourQuestions,
            "their_questions": talk.theirQuestions, "longest_stretch_seconds": talk.longestRun,
            "people": talk.people.map { ["name": $0.name, "share": $0.share, "seconds": $0.seconds, "you": $0.mine] },
        ]
        if talk.isEmpty { talkJSON = [:] }
        var out: [String: Any] = [
            "v": 1, "type": "meeting_finished",
            "started_at": ISO8601DateFormatter().string(from: startedAt),
            "duration_seconds": duration.rounded(), "apps": apps,
            "recording": recording.path, "key_points": notes.keyPoints, "open_questions": notes.questions,
            "next_steps": steps, "talk": talkJSON,
        ]
        if let title { out["title"] = title }
        if let workspace { out["workspace"] = workspace }
        if let notesFile { out["notes_file"] = notesFile.path }
        if !addedSteps.isEmpty { out["jon_added_steps"] = addedSteps.map(\.text) }
        return out
    }
}

final class FinishedViewModel: ObservableObject {
    struct Step: Identifiable, Equatable {
        enum Owner { case claude, you }

        let id = UUID()
        var text: String
        var selected = true
        var owner = Owner.you

        /// How the hand-off names it, so the work goes to the right place.
        var handed: String { (owner == .claude ? "Claude: " : "You: ") + text }
    }

    enum Handoff: Equatable {
        case idle, sending
        case done(String, URL?)
        case failed(String)
    }

    let summary: MeetingSummary
    let canHandOff: Bool
    @Published var steps: [Step]
    @Published var handoff = Handoff.idle
    @Published var keyPoints: [String]
    @Published var openQuestions: [String]
    /// What the other side promised: shown, not handed off as your steps.
    @Published var waitingOn: [String] = []
    /// While the next steps are being rewritten from the whole call.
    @Published var refining: String?
    private let suggested: [String]
    private let added: [Step]

    init(summary: MeetingSummary, canHandOff: Bool) {
        self.summary = summary
        self.canHandOff = canHandOff
        suggested = summary.suggestedSteps
        added = summary.addedSteps.map { Step(text: $0.text, selected: $0.selected) }
        steps = added + suggested.map { Step(text: $0) }
        keyPoints = summary.notes.keyPoints
        openQuestions = summary.notes.questions
    }

    /// The rewrite from the whole call: what Claude will do and what needs
    /// you, replacing the live notes' steps unless you have already changed
    /// them (then the new ones are added, unticked). Your own stay.
    func refine(ai: [String], mine: [String], waiting: [String] = [], keyPoints points: [String]?,
                questions: [String]?, by source: String) {
        let initial = added.map { "\($0.selected)\($0.text)" } + suggested.map { "true\($0)" }
        let untouched = steps.map { "\($0.selected)\($0.text)" } == initial
        let new = ai.map { Step(text: $0, owner: .claude) } + mine.map { Step(text: $0, owner: .you) }
        let fresh = new.filter { step in !added.contains { LiveNotesSections.sameItem($0.text, step.text) } }
        if untouched {
            steps = added + fresh
        } else {
            let have = Set(steps.map(\.text))
            steps += fresh.filter { !have.contains($0.text) }.map { var s = $0; s.selected = false; return s }
        }
        waitingOn = waiting
        if let points, !points.isEmpty { keyPoints = points }
        if let questions { openQuestions = questions }
        refining = nil
        Log.shared.write("meeting finished: next steps rewritten by \(source)")
    }

    var chosen: [String] {
        steps.filter { $0.selected && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }.map(\.handed)
    }

    /// The recap as Markdown, for the clipboard.
    var markdown: String {
        var text = "# \(summary.title ?? "Call") (\(LiveTranscript.stamp(summary.duration)))\n\n"
        if !summary.talk.isEmpty { text += "Talk time: " + summary.talk.summary + "\n\n" }
        text += "## Next steps\n" + (chosen.isEmpty ? "- none\n" : chosen.map { "- \($0)\n" }.joined())
        if !waitingOn.isEmpty { text += "\n## Waiting on them\n" + waitingOn.map { "- \($0)\n" }.joined() }
        text += "\n## Key points\n" + keyPoints.map { "- \($0)\n" }.joined()
        if !openQuestions.isEmpty {
            text += "\n## Open questions\n" + openQuestions.map { "- \($0)\n" }.joined()
        }
        return text
    }
}

struct FinishedView: View {
    @ObservedObject var model: FinishedViewModel
    var onHandOff: () -> Void
    var onClose: () -> Void
    var onDiscard: () -> Void = {}
    @State private var newStep = ""
    @State private var copied = false

    private var subtitle: String {
        var parts = [LiveTranscript.stamp(model.summary.duration)]
        if let app = model.summary.apps.first { parts.append(app) }
        if let workspace = model.summary.workspace { parts.append(workspace) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.green.gradient)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.summary.title ?? "Meeting finished").font(.title2.weight(.semibold)).lineLimit(1)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            if !model.summary.talk.isEmpty {
                TalkPanel(stats: model.summary.talk)
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    stepsSection
                    if !model.keyPoints.isEmpty {
                        list("Key points", symbol: "text.bubble", model.keyPoints)
                    }
                    if !model.openQuestions.isEmpty {
                        list("Open questions", symbol: "questionmark.bubble", model.openQuestions)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            status
            HStack(spacing: 8) {
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.markdown, forType: .string)
                    copied = true
                }
                Button("Show file") { NSWorkspace.shared.activateFileViewerSelecting([model.summary.recording]) }
                Button("Discard", role: .destructive, action: onDiscard)
                    .help("Not worth keeping: moves it to Skipped (nothing is deleted) so it is never filed")
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.cancelAction)
                if model.canHandOff {
                    Button(action: onHandOff) {
                        Label("Hand off \(model.chosen.count) step\(model.chosen.count == 1 ? "" : "s")",
                              systemImage: "paperplane.fill")
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(HelpButtonStyle())
                    .disabled(model.chosen.isEmpty || model.handoff == .sending || isDone)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 480)
    }

    private var isDone: Bool {
        if case .done = model.handoff { return true }
        return false
    }

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Label("Next steps", systemImage: "arrow.forward.circle.fill").font(.headline)
                if let refining = model.refining {
                    ProgressView().controlSize(.mini)
                    Text(refining).font(.caption).foregroundStyle(.secondary)
                }
            }
            group("Claude will do", symbol: "sparkles", owner: .claude)
            group("For you", symbol: "person.fill", owner: .you)
            if model.steps.isEmpty && model.refining == nil {
                Text("Nothing to follow up.").font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: "plus.circle").foregroundStyle(.secondary)
                TextField("Add a step for Claude…", text: $newStep)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        let text = newStep.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        model.steps.append(.init(text: text, owner: .claude))
                        newStep = ""
                    }
            }
            .padding(.horizontal, 8)
            if !model.waitingOn.isEmpty {
                list("Waiting on them", symbol: "hourglass", model.waitingOn)
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, symbol: String, owner: FinishedViewModel.Step.Owner) -> some View {
        let indices = model.steps.indices.filter { model.steps[$0].owner == owner }
        if !indices.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
                    .foregroundStyle(owner == .claude ? Color.accentColor : Color.secondary)
                ForEach(indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        Toggle("", isOn: $model.steps[index].selected).toggleStyle(.checkbox).labelsHidden()
                        TextField("Step", text: $model.steps[index].text, axis: .vertical)
                            .textFieldStyle(.plain)
                            .foregroundStyle(model.steps[index].selected ? .primary : .secondary)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 8)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func list(_ title: String, symbol: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.headline)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                (Text("• ") + Text(Markdown.inline(item))).font(.callout).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.handoff {
        case .idle:
            EmptyView()
        case .sending:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Handing off…").font(.callout) }
        case .done(let text, let url):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Text(text).font(.callout).lineLimit(2)
                if let url { Link("Open", destination: url).font(.callout.weight(.semibold)) }
            }
        case .failed(let text):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(text).font(.callout).lineLimit(3)
            }
        }
    }
}

/// Runs a command once with JSON on stdin; returns its last stdout line as
/// JSON (nil if it failed or printed something else). Off the main thread.
enum JSONCommand {
    static func run(_ command: [String], payload: [String: Any], timeout: Double,
                    completion: @escaping ([String: Any]?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command[0])
            process.arguments = Array(command.dropFirst())
            let input = Pipe(), output = Pipe(), errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            let finish = { (reply: [String: Any]?) in DispatchQueue.main.async { completion(reply) } }
            do {
                try process.run()
                _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: payload))
                try input.fileHandleForWriting.close()
            } catch {
                Log.shared.write("\(command[0]): could not run: \(error)")
                return finish(nil)
            }
            let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            var err = Data()
            let reading = DispatchGroup()
            reading.enter()
            DispatchQueue.global().async {
                err = errors.fileHandleForReading.readDataToEndOfFile()
                reading.leave()
            }
            let out = output.fileHandleForReading.readDataToEndOfFile()
            reading.wait()
            process.waitUntilExit()
            timer.cancel()
            for line in String(decoding: err, as: UTF8.self).split(separator: "\n").prefix(20) {
                Log.shared.write("\(URL(fileURLWithPath: command.last ?? command[0]).lastPathComponent): \(line.prefix(300))")
            }
            let last = String(decoding: out, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
            let reply = (try? JSONSerialization.jsonObject(with: Data(last.utf8))) as? [String: Any]
            finish(process.terminationStatus == 0 ? reply : nil)
        }
    }
}

/// Runs `followup_command` once: the meeting as JSON on stdin; the last line
/// it prints may be JSON {"status": "...", "url": "..."}, else plain text.
enum FollowUp {
    static func run(command: [String], payload: [String: Any], timeout: Double = 120,
                    completion: @escaping (FinishedViewModel.Handoff) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command[0])
            process.arguments = Array(command.dropFirst())
            let input = Pipe(), output = Pipe(), errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            let finish = { (result: FinishedViewModel.Handoff) in DispatchQueue.main.async { completion(result) } }
            do {
                try process.run()
                _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: payload))
                try input.fileHandleForWriting.close()
            } catch {
                Log.shared.write("follow-up: could not run \(command[0]): \(error)")
                return finish(.failed("Could not start the follow-up command: \(error.localizedDescription)"))
            }
            let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            // Both pipes at once, so a chatty stderr can't stall the command.
            var err = Data()
            let reading = DispatchGroup()
            reading.enter()
            DispatchQueue.global().async {
                err = errors.fileHandleForReading.readDataToEndOfFile()
                reading.leave()
            }
            let out = output.fileHandleForReading.readDataToEndOfFile()
            reading.wait()
            process.waitUntilExit()
            timer.cancel()
            for line in String(decoding: err, as: UTF8.self).split(separator: "\n").prefix(20) {
                Log.shared.write("follow-up: \(line.prefix(300))")
            }
            let last = String(decoding: out, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
            let reply = (try? JSONSerialization.jsonObject(with: Data(last.utf8))) as? [String: Any]
            let text = (reply?["status"] as? String) ?? (last.isEmpty ? "Handed off" : last)
            guard process.terminationStatus == 0 else {
                Log.shared.write("follow-up: exited \(process.terminationStatus)")
                return finish(.failed((reply?["status"] as? String) ?? "The follow-up command failed (exit \(process.terminationStatus)); see the MacCap log"))
            }
            Log.shared.write("follow-up: \(text)")
            finish(.done(String(text.prefix(300)), (reply?["url"] as? String).flatMap(URL.init(string:))))
        }
    }
}

/// The window. Ordinary (it takes typing and comes to the front), kept out
/// of screen sharing like the live-notes window.
final class FinishedWindow: NSWindow {
    init<Content: View>(rootView: Content) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                   styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        title = "MacCap · meeting finished"
        isReleasedWhenClosed = false
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces]
        contentView = NSHostingView(rootView: rootView)
        center()
    }
}

extension FinishedWindow {
    /// The meeting-finished window for a call's live notes, with the final
    /// rewrite started if `final_notes_command` is set; nil when there is
    /// nothing to show. `onDiscard` runs before the window closes.
    @available(macOS 26.0, *)
    static func make(live: LiveNotesController, recording: URL, config: MacCapConfig,
                     onDiscard: @escaping () -> Void) -> FinishedWindow? {
        let sidecarURL = recording.deletingPathExtension().appendingPathExtension("maccap.json")
        let sidecar = (try? JSONSerialization.jsonObject(with: Data(contentsOf: sidecarURL))) as? [String: Any]
        var summary = live.summary(recording: recording, sidecar: sidecar)
        guard !summary.notes.isEmpty || !summary.talk.isEmpty else { return nil }
        let command = config.followup
        summary.expectRewrite = config.finalNotes != nil && !summary.transcript.isEmpty
        let model = FinishedViewModel(summary: summary, canHandOff: command != nil)
        var window: FinishedWindow?
        let view = FinishedView(model: model, onHandOff: { [weak model] in
            guard let model, let command else { return }
            model.handoff = .sending
            FollowUp.run(command: command, payload: summary.payload(steps: model.chosen)) { model.handoff = $0 }
        }, onClose: { window?.close() }, onDiscard: {
            onDiscard()
            window?.close()
        })
        if let finalNotes = config.finalNotes, !summary.transcript.isEmpty {
            model.refining = "Working out what Claude can do…"
            var payload = summary.payload(steps: summary.notes.actions)
            payload["type"] = "final_notes"
            payload["transcript"] = summary.transcript
            JSONCommand.run(finalNotes, payload: payload, timeout: 180) { [weak model] reply in
                guard let model else { return }
                guard let reply else {
                    model.refining = nil
                    // Nothing came back: fall back to your own actions from the live notes, a few at most.
                    let live = summary.notes.actions.filter { $0.hasPrefix("(You)") }.prefix(MeetingSummary.liveStepLimit)
                    model.steps += live.map { .init(text: $0, owner: .you) }
                    Log.shared.write("meeting finished: final notes command gave nothing; using the live notes")
                    return
                }
                let ai = reply["ai_steps"] as? [String] ?? []
                var mine = reply["your_steps"] as? [String] ?? []
                if ai.isEmpty && mine.isEmpty { mine = Array((reply["next_steps"] as? [String] ?? []).prefix(4)) }
                model.refine(ai: ai, mine: mine, waiting: reply["waiting_on"] as? [String] ?? [],
                             keyPoints: reply["key_points"] as? [String], questions: reply["open_questions"] as? [String],
                             by: reply["model"] as? String ?? "final_notes_command")
            }
        }
        window = FinishedWindow(rootView: view)
        return window
    }
}
