import AppKit
import Carbon.HIToolbox
import SwiftUI

// The live-notes window and the controller that feeds it: two live
// transcribers (mic = You, call side = Them), the transcript, and a notes
// update every `notes_interval_seconds`. Everything here is best effort: a
// failure shows in the window and the log, never in the recording.

enum LiveNotesFiles {
    /// Written into the session folder during the call and at the end; the
    /// finalizer copies it next to the recording as "<name>.notes.md".
    static let sessionFile = "live-notes.md"
}

final class LiveNotesViewModel: ObservableObject {
    struct Line: Identifiable, Equatable {
        let id: String
        let speaker: String
        let text: String
        let mine: Bool
        let inProgress: Bool
        var start: Double = 0

        var stamped: String { "[\(LiveTranscript.stamp(start))] \(speaker): \(text)" }
    }

    /// A part of the call and its lines (lines before the first part have no topic).
    struct Part: Identifiable {
        let id: String
        let topic: CallTopic?
        let lines: [Line]
    }

    @Published var lines: [Line] = []
    @Published var notes = LiveNotesSections()
    @Published var status = "Starting live notes…"
    @Published var topics: [CallTopic] = []
    /// Lines you picked to ask about, by id.
    @Published var selected: Set<String> = []
    private var anchor: String?

    var parts: [Part] {
        var groups: [[Line]] = Array(repeating: [], count: topics.count + 1)
        for line in lines {
            let index = line.inProgress ? topics.count - 1 : CallTopics.index(at: line.start, in: topics) ?? -1
            groups[index + 1].append(line)
        }
        var out: [Part] = []
        if !groups[0].isEmpty { out.append(Part(id: "part-start", topic: nil, lines: groups[0])) }
        for (i, topic) in topics.enumerated() {
            out.append(Part(id: "part-\(i)-\(topic.start)", topic: topic, lines: groups[i + 1]))
        }
        return out
    }

    /// A click picks or drops a line; a shift-click picks every line from the
    /// last one clicked.
    func tap(_ id: String, extend: Bool) {
        let ids = lines.filter { !$0.inProgress }.map(\.id)
        if extend, let anchor, let a = ids.firstIndex(of: anchor), let b = ids.firstIndex(of: id) {
            selected.formUnion(ids[min(a, b)...max(a, b)])
        } else if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
        anchor = id
    }

    /// Picks a whole part, or drops it if it is all picked already.
    func toggle(_ part: Part) {
        let ids = Set(part.lines.filter { !$0.inProgress }.map(\.id))
        if !ids.isEmpty, ids.isSubset(of: selected) { selected.subtract(ids) } else { selected.formUnion(ids) }
    }

    func clearSelection() {
        selected.removeAll()
        anchor = nil
    }

    var pickedLines: [Line] { lines.filter { selected.contains($0.id) && !$0.inProgress } }
    var pickedText: String { pickedLines.map(\.stamped).joined(separator: "\n") }

    /// The part's title when exactly one whole part is picked.
    var pickedTitle: String? {
        parts.first { part in
            let ids = Set(part.lines.filter { !$0.inProgress }.map(\.id))
            return part.topic != nil && !ids.isEmpty && ids == selected
        }?.topic?.title
    }
}

struct LiveNotesView: View {
    @ObservedObject var model: LiveNotesViewModel
    /// A helper is running: picked lines can be asked about.
    var helper = false
    /// Help with the picked lines: (lines, part title).
    var onHelp: (String, String?) -> Void = { _, _ in }
    /// A question about the picked lines: (question, lines, part title).
    var onAsk: (String, String, String?) -> Void = { _, _, _ in }
    @State private var question = ""
    @State private var jump: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    section("Key points", model.notes.keyPoints)
                    section("Questions", model.notes.questions)
                    section("Actions", model.notes.actions)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 6) {
                Text("Transcript").font(.headline)
                Spacer(minLength: 0)
                if !model.topics.isEmpty {
                    Menu("Parts (\(model.topics.count))") {
                        ForEach(model.parts.filter { $0.topic != nil }) { part in
                            Button("\(LiveTranscript.stamp(part.topic!.start))  \(part.topic!.title)") { jump = part.id }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Jump to a part of the call")
                }
            }
            if model.selected.isEmpty && !model.lines.isEmpty {
                Text(helper ? "Click lines (shift-click for a run) or a part's heading to ask about them"
                            : "Click lines (shift-click for a run) or a part's heading to copy them")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.parts) { part in
                            if let topic = part.topic { header(part, topic).id(part.id) }
                            ForEach(part.lines) { line in row(line) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.lines.last?.id) { _, last in
                    // Not while you are picking lines: the list would jump away from them.
                    if let last, model.selected.isEmpty { proxy.scrollTo(last, anchor: .bottom) }
                }
                .onChange(of: jump) { _, id in
                    if let id { withAnimation(.snappy) { proxy.scrollTo(id, anchor: .top) } }
                    jump = nil
                }
            }
            .frame(minHeight: 140, idealHeight: 190)
            if !model.selected.isEmpty { selectionBar }
        }
        .padding(12)
        .frame(minWidth: 300, minHeight: 380)
    }

    private func header(_ part: LiveNotesViewModel.Part, _ topic: CallTopic) -> some View {
        let ids = Set(part.lines.filter { !$0.inProgress }.map(\.id))
        let picked = !ids.isEmpty && ids.isSubset(of: model.selected)
        return HStack(spacing: 6) {
            Text(LiveTranscript.stamp(topic.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(topic.title).font(.subheadline.weight(.semibold)).lineLimit(2)
            Spacer(minLength: 0)
            Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(picked ? Color.accentColor : Color.secondary)
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
        .contentShape(Rectangle())
        .onTapGesture { model.toggle(part) }
        .help(helper ? "Click to pick this whole part, then Help or Ask about it" : "Click to pick this whole part")
        .contextMenu {
            if helper {
                Button("Help with this part") {
                    onHelp(part.lines.filter { !$0.inProgress }.map(\.stamped).joined(separator: "\n"), topic.title)
                }
            }
            Button("Copy this part") { copy(part.lines.map(\.stamped).joined(separator: "\n")) }
        }
    }

    private func row(_ line: LiveNotesViewModel.Line) -> some View {
        let picked = model.selected.contains(line.id)
        return (Text(line.speaker + "  ").bold().foregroundColor(line.mine ? .accentColor : .orange)
            + Text(line.text).foregroundColor(line.inProgress ? .secondary : .primary))
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(picked ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onTapGesture {
                if !line.inProgress { model.tap(line.id, extend: NSEvent.modifierFlags.contains(.shift)) }
            }
            .contextMenu {
                if helper && !line.inProgress { Button("Help with this") { onHelp(line.stamped, nil) } }
                Button("Copy") { copy(line.stamped) }
            }
            .id(line.id)
    }

    private var selectionBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                let count = model.pickedLines.count
                Text(model.pickedTitle.map { "Part: \($0)" } ?? "\(count) line\(count == 1 ? "" : "s") picked")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Button("Copy") { copy(model.pickedText) }.controlSize(.small)
                Button("Clear") { model.clearSelection() }.controlSize(.small)
            }
            if helper {
                Button {
                    onHelp(model.pickedText, model.pickedTitle)
                    model.clearSelection()
                } label: {
                    Label("Help with these", systemImage: "lifepreserver.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(HelpButtonStyle())
                .help("Facts and ideas for the lines you picked, with the whole call as background")
                TextField("Ask about these lines…", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        onAsk(text, model.pickedText, model.pickedTitle)
                        question = ""
                        model.clearSelection()
                    }
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            if items.isEmpty {
                Text("nothing yet").font(.callout).foregroundStyle(.tertiary)
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    (Text("• ") + Text(Markdown.inline(item))).font(.callout).textSelection(.enabled)
                }
            }
        }
    }
}

final class LiveNotesPanel: NSPanel {
    static let frameName = "MacCapLiveNotes"

    convenience init(model: LiveNotesViewModel) {
        self.init(rootView: LiveNotesView(model: model), size: NSSize(width: 360, height: 560), title: "MacCap · live notes")
    }

    init<Content: View>(rootView: Content, size: NSSize, title: String) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        self.title = title
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Asks screen sharing and screenshots to leave the window out. Not
        // every capture path honours it, so share a window rather than the
        // whole screen until it has been checked with your call app.
        sharingType = .none
        // Takes typing (the assist's question box) without bringing MacCap
        // forward, and only when a text field is clicked.
        becomesKeyOnlyIfNeeded = true
        contentView = NSHostingView(rootView: rootView)
        if !setFrameUsingName(Self.frameName), let screen = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: screen.maxX - frame.width - 16, y: screen.maxY - frame.height - 16))
        }
        setFrameAutosaveName(Self.frameName)
    }

    override var canBecomeKey: Bool { true }
}

/// Hands capture samples to the transcribers from the audio threads.
private final class LiveFeedRouter {
    private let lock = NSLock()
    private var targets: [LiveStem: AnyObject] = [:]

    func set(_ stem: LiveStem, _ target: AnyObject?) {
        lock.lock()
        targets[stem] = target
        lock.unlock()
    }

    func target(_ stem: LiveStem) -> AnyObject? {
        lock.lock()
        defer { lock.unlock() }
        return targets[stem]
    }
}

@available(macOS 26.0, *)
final class LiveNotesController {
    let view = LiveNotesViewModel()
    let assistView = AssistViewModel()
    /// Every final line as it arrives (the CLI prints them).
    var onFinalLine: ((LiveLine) -> Void)?
    /// Every assist card as it arrives (the CLI prints them).
    var onCard: ((AssistCard) -> Void)?
    /// Apps on the call, for the assist's start message.
    var callApps: [String] = []

    private let config: MacCapConfig
    private let originHost: Double
    private let sessionDir: URL
    private let model: LiveNotesModel?
    private let router = LiveFeedRouter()
    private var transcribers: [LiveTranscriber] = []
    private var transcript = LiveTranscript()  // main thread only
    private var notes: LiveNotesSections?
    private var updating = false
    /// The parts of the call so far (the last one still open).
    private var topics: [CallTopic] = []
    private var updatingTopics = false
    private var wordsAtLastTopics = 0
    private var wordsAtLastUpdate = 0
    private var timer: Timer?
    private var panel: LiveNotesPanel?
    private let started = Date()
    private var assist: AssistClient?
    private var hotkey: GlobalHotkey?
    /// Save this call and start the next one (the menu bar app sets it).
    var onNextCall: (() -> Void)?
    private var requests = 0
    /// The lines you picked for an Ask or Help, by its card: its follow-ups are about them too.
    private var picked: [String: (focus: String, part: String?)] = [:]
    private var coach: Coach?
    /// Actions you added during the call (typed, said, marked), for the
    /// meeting-finished window; ticked unless a phrase added it on its own.
    private var added: [(id: String, text: String, selected: Bool)] = []
    var addedSteps: [(text: String, selected: Bool)] { added.map { ($0.text, $0.selected) } }
    /// Show the windows in screenshots and screen sharing (off: they're hidden).
    var visibleToSharing = false {
        didSet { panel?.sharingType = visibleToSharing ? .readOnly : .none }
    }
    private var moments = 0
    private var lastAutoMoment = -Double.infinity
    private var asideStart: Double?
    private var keys: [GlobalHotkey] = []
    /// Both transcribers ran, so "nobody else spoke" can be trusted.
    private var transcribing = false

    /// The call side never said a word the transcriber caught: nobody joined.
    var nobodyElseSpoke: Bool {
        transcribing && !transcript.lines.contains { $0.stem == .system } && transcript.volatile[.system] == nil
    }

    init(config: MacCapConfig, originHost: Double, sessionDir: URL) {
        self.config = config
        self.originHost = originHost
        self.sessionDir = sessionDir
        model = LiveNotesModels.make(config: config)
        if config.coachEnabled {
            coach = Coach(talkShare: config.coachTalkShare, monologueSeconds: config.coachMonologueSeconds)
        }
    }

    /// Route the session's samples here; call before the session starts.
    func attach(to session: RecordingSession) {
        let router = self.router
        session.liveFeed = { stem, samples, rate, start in
            (router.target(stem) as? LiveTranscriber)?.feed(samples, rate: rate, startHost: start)
        }
    }

    func start(showWindow: Bool) {
        if config.assistHotkey ?? true {
            keys = [GlobalHotkey(GlobalHotkey.moment) { [weak self] in self?.markMoment() },
                    GlobalHotkey(GlobalHotkey.aside) { [weak self] in self?.toggleAside() }].compactMap { $0 }
        }
        startAssist()
        if showWindow { show() }
        Task { @MainActor in _ = await prepare() }
    }

    /// Starts both transcribers and the notes timer; true once samples fed
    /// from now on are transcribed.
    @MainActor
    func prepare() async -> Bool {
        do {
            let locale = try await LiveTranscriber.prepareLocale(config.liveNotesLocale)
            for stem in [LiveStem.mic, .system] {
                let transcriber = LiveTranscriber(stem: stem, locale: locale, originHost: originHost)
                transcriber.onLine = { [weak self] line, isFinal in
                    DispatchQueue.main.async { self?.receive(line, isFinal: isFinal) }
                }
                try await transcriber.prepare()
                transcribers.append(transcriber)
                router.set(stem, transcriber)
                Task {
                    do { try await transcriber.run() } catch {
                        Log.shared.write("live notes: \(stem.rawValue) transcriber stopped: \(error)")
                    }
                }
            }
            transcribing = true
            view.status = "Listening (\(locale.identifier)) · notes by \(model?.name ?? "no model available")"
            Log.shared.write("live notes: started (\(locale.identifier), \(model?.name ?? "no notes model"))")
            timer = Timer.scheduledTimer(withTimeInterval: config.notesInterval, repeats: true) { [weak self] _ in
                self?.updateNotes()
                self?.updateTopics()
            }
            return true
        } catch {
            view.status = "Live notes are off: \(error)"
            Log.shared.write("live notes: not started: \(error)")
            return false
        }
    }

    /// Feed samples directly (replaying a saved recording).
    func feed(_ stem: LiveStem, _ samples: [Float], rate: Double, startHost: Double) {
        (router.target(stem) as? LiveTranscriber)?.feed(samples, rate: rate, startHost: startHost)
    }

    func show() {
        if panel == nil {
            let helper = config.assist != nil
            let tabs = helper || coach != nil
            let root = CallPanelView(notes: view, assist: assistView, assistEnabled: tabs, helper: helper,
                                     hotkey: hotkey != nil, limit: coach?.talkShare ?? 0.65,
                                     onHelp: { [weak self] in self?.help() },
                                     onSubmit: { [weak self] mode, text in self?.submit(mode, text) },
                                     onAside: { [weak self] in self?.toggleAside() },
                                     onMoment: { [weak self] in self?.markMoment() },
                                     onNextCall: { [weak self] in self?.onNextCall?() },
                                     onEdit: { [weak self] in self?.editAdded($0, $1) },
                                     onRetype: { [weak self] in self?.retype($0) },
                                     onRemove: { [weak self] in self?.removeAdded($0) },
                                     onChoose: { [weak self] in self?.choose($0) },
                                     onHelpWith: { [weak self] in self?.help(focus: $0, part: $1) },
                                     onAskAbout: { [weak self] in self?.ask($0, focus: $1, part: $2) },
                                     onFollowUp: { [weak self] in self?.followUp($0, on: $1) })
            panel = LiveNotesPanel(rootView: root, size: tabs ? NSSize(width: 380, height: 680)
                                                              : NSSize(width: 360, height: 560),
                                   title: helper ? "MacCap · call assist" : "MacCap · live notes")
            panel?.sharingType = visibleToSharing ? .readOnly : .none
        }
        panel?.orderFrontRegardless()
    }

    // MARK: Assist

    /// Starts `assist_command` for this call, if one is set up.
    func startAssist() {
        guard assist == nil, let command = config.assist else { return }
        let client = AssistClient(command: command)
        client.onMessage = { [weak self] in self?.handle($0) }
        client.onExit = { [weak self] status in
            guard let self else { return }
            assistView.running = false
            assistView.waiting.removeAll()
            if status != 0 { assistView.status = "The assist stopped (exit \(status)); the call is still recorded" }
        }
        do {
            try client.start(environment: ["MACCAP_SESSION_DIR": sessionDir.path])
        } catch {
            assistView.status = "The assist could not start: \(error.localizedDescription)"
            Log.shared.write("assist: could not start \(command[0]): \(error)")
            return
        }
        assist = client
        assistView.running = true
        assistView.status = "Listening"
        client.send(["type": "start", "v": 1, "started_at": ISO8601DateFormatter().string(from: started),
                     "session_dir": sessionDir.path, "apps": callApps])
        if config.assistHotkey ?? true {
            hotkey = GlobalHotkey(GlobalHotkey.help) { [weak self] in
                self?.show()
                self?.help()
            }
        }
    }

    private func handle(_ message: AssistMessage) {
        switch message {
        case .card(let card):
            assistView.upsert(card)
            onCard?(card)
        case .remove(let id):
            assistView.remove(id)
        case .status(let text):
            assistView.status = text
        case .context(let title, let workspace):
            if let title { assistView.title = title }
            if let workspace { assistView.workspace = workspace }
        case .choices(let options, let selected):
            assistView.choices = options
            assistView.chosen = selected
        case .speaker(let stem, let start, let end, let name):
            transcript.nameSpeaker(.init(stem: stem, start: start, end: end, name: name))
            refreshLines()
            assistView.talk = TalkStats.compute(transcript.lines)
        }
    }

    /// A typed question: a pinned answer card that fills in when the reply
    /// comes. `focus`: lines you picked in the transcript, the question is about them.
    func ask(_ question: String, focus: String? = nil, part: String? = nil) {
        guard let assist else { return }
        requests += 1
        let id = "ask-\(requests)"
        let at = Date().timeIntervalSince(started)
        let chips = focus == nil ? ["you asked"] : ["you asked", part ?? "picked lines"]
        assistView.upsert(AssistCard(id: id, kind: .answer, title: question, chips: chips, quote: Self.firstSaid(focus),
                                     at: at, state: .looking, pinned: true))
        assistView.waiting.insert(id)
        // The whole call, so a question about anything said in it can be answered.
        var event = context(["type": "ask", "id": id, "question": question, "at": at])
        if let focus {
            event["focus"] = focus
            if let part { event["part"] = part }
            picked[id] = (focus, part)
        }
        assist.send(event)
    }

    /// A question following up an answer (`root`: its thread's first card).
    /// It goes in that thread, and carries the questions and answers so far.
    func followUp(_ question: String, on root: String) {
        guard let assist, assistView.cards.contains(where: { $0.id == root }) else { return }
        requests += 1
        let id = "ask-\(requests)"
        let at = callTime
        let thread = assistView.conversation(root)
        assistView.upsert(AssistCard(id: id, kind: .answer, title: question, at: at, state: .looking, pinned: true,
                                     parent: root))
        assistView.waiting.insert(id)
        var event = context(["type": "ask", "id": id, "question": question, "at": at, "follows": root,
                             "thread": thread])
        if let lines = picked[root] {
            event["focus"] = lines.focus
            if let part = lines.part { event["part"] = part }
        }
        assist.send(event)
    }

    /// What every Ask and Help carries: the call so far and its parts.
    private func context(_ event: [String: Any]) -> [String: Any] {
        var event = event
        event["transcript"] = transcript.text()
        if !topics.isEmpty {
            event["topics"] = topics.map { ["start": $0.start, "title": $0.title] as [String: Any] }
        }
        return event
    }

    /// The words of the first picked line, for the card's quote.
    private static func firstSaid(_ focus: String?) -> String? {
        guard let first = focus?.split(separator: "\n").first else { return nil }
        return first.split(separator: ":", maxSplits: 2).last.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: Moments and actions

    private var callTime: Double { Date().timeIntervalSince(started) }

    /// The box at the bottom: an action, a note, or a question for the assist.
    func submit(_ mode: InputBar.Mode, _ text: String) {
        switch mode {
        case .ask: ask(text)
        case .action: addAction(text, chip: "typed")
        case .note:
            requests += 1
            assistView.upsert(AssistCard(id: "note-\(requests)", kind: .note, title: text, chips: ["typed"],
                                         at: callTime))
            save()
        }
    }

    private func addAction(_ text: String, chip: String, selected: Bool = true, quote: String? = nil) {
        requests += 1
        let card = AssistCard(id: "action-\(requests)", kind: .commitment, title: text, chips: [chip], quote: quote,
                              at: callTime, state: .ready)
        assistView.upsert(card)
        onCard?(card)
        added.append((card.id, text, selected))
        assist?.send(["type": "action", "id": card.id, "text": text, "at": card.at ?? 0])
        save()
    }

    /// The last minute or so, made into one line by the notes model: what
    /// was just agreed or promised. From the button, Control-Option-M, or a
    /// phrase you said (then the step starts unticked).
    func markMoment(phrase: String? = nil) {
        let now = callTime
        let recent = transcript.lines.filter { $0.end >= now - 75 }
        guard let last = recent.last else {
            assistView.status = "Nothing heard in the last minute to mark"
            return
        }
        moments += 1
        let id = "moment-\(moments)"
        let chips = phrase.map { ["heard “\($0)”"] } ?? ["marked"]
        assistView.upsert(AssistCard(id: id, kind: .commitment, title: "Moment", chips: chips, quote: last.text,
                                     at: now, state: .looking))
        let text = recent.map { "[\(LiveTranscript.stamp($0.start))] \($0.label): \($0.text)" }.joined(separator: "\n")
        assist?.send(["type": "moment", "id": id, "at": now, "transcript": text, "auto": phrase != nil])
        let model = self.model
        Task { @MainActor in
            var line = last.text
            if let model, let reply = try? await model.reply(instructions: MomentPrompt.instructions, text: text),
               !reply.isEmpty {
                line = String(reply.prefix(300))
            }
            let card = AssistCard(id: id, kind: .commitment, title: line, chips: chips, quote: last.text, at: now,
                                  state: .ready)
            assistView.upsert(card)
            onCard?(card)
            if phrase == nil { added.append((id, line, true)) }  // a phrase alone makes a card, not a step
            save()
        }
    }

    /// Control-Option-A (or the mic button): what you say until you press it
    /// again becomes an action. The call hears it unless you mute there.
    func toggleAside() {
        if asideStart == nil {
            asideStart = callTime
            assistView.aside = true
            show()
            return
        }
        let start = asideStart ?? callTime
        let end = callTime
        asideStart = nil
        assistView.aside = false
        // The transcriber finishes a line a moment after it is said.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            var said = transcript.lines.filter { $0.stem == .mic && $0.end >= start - 1 && $0.start <= end + 1 }
                .map(\.text)
            if said.isEmpty, let pending = transcript.volatile[.mic], pending.end >= start - 1 { said = [pending.text] }
            let text = said.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                assistView.status = "Didn't catch an action; try again or type it"
                return
            }
            addAction(text, chip: "said")
        }
    }

    /// Right-click → Edit on something you added.
    func editAdded(_ id: String, _ text: String) {
        guard let index = assistView.cards.firstIndex(where: { $0.id == id }) else { return }
        assistView.cards[index].title = text
        if let i = added.firstIndex(where: { $0.id == id }) { added[i].text = text }
        save()
    }

    /// Right-click → Make it a note / an action.
    func retype(_ id: String) {
        guard let index = assistView.cards.firstIndex(where: { $0.id == id }) else { return }
        if assistView.cards[index].kind == .note {
            assistView.cards[index].kind = .commitment
            added.append((id, assistView.cards[index].title, true))
        } else {
            assistView.cards[index].kind = .note
            added.removeAll { $0.id == id }
        }
        save()
    }

    /// Right-click → Remove.
    func removeAdded(_ id: String) {
        assistView.cards.removeAll { $0.id == id }
        added.removeAll { $0.id == id }
        save()
    }

    /// The meeting switcher: the helper works from the brief you picked.
    func choose(_ id: String?) {
        assistView.chosen = id
        assist?.send(["type": "choose", "id": id ?? NSNull()])
    }

    private func checkPhrases(_ line: LiveLine) {
        guard line.stem == .mic, callTime - lastAutoMoment >= 30 else { return }
        let lower = line.text.lowercased()
        if let phrase = config.phrases.first(where: { lower.contains($0) }) {
            lastAutoMoment = callTime
            markMoment(phrase: phrase)
        }
    }

    /// Help with what was just said, from the hotkey or the button; with
    /// `focus`, with lines you picked in the transcript (a whole `part`, or a few).
    func help(focus: String? = nil, part: String? = nil) {
        guard let assist else { return }
        guard assistView.waiting.allSatisfy({ !$0.hasPrefix("help-") }) else {
            assistView.status = "Still working on the last Help"
            return
        }
        requests += 1
        let id = "help-\(requests)"
        let at = Date().timeIntervalSince(started)
        let title = focus == nil ? "Help with what was just said"
                                 : "Help with " + (part.map { "“\($0)”" } ?? "the lines you picked")
        let quote = focus == nil ? transcript.lines.last { $0.stem == .system }?.text : Self.firstSaid(focus)
        assistView.upsert(AssistCard(id: id, kind: .answer, title: title, quote: quote, at: at, state: .looking,
                                     pinned: true))
        assistView.waiting.insert(id)
        var event = context(["type": "help", "id": id, "at": at])
        if let focus {
            event["focus"] = focus
            picked[id] = (focus, part)
        }
        if let part { event["part"] = part }
        assist.send(event)
    }

    private func receive(_ line: LiveLine, isFinal: Bool) {
        if isFinal {
            transcript.add(line)
            onFinalLine?(line)
            if asideStart == nil { checkPhrases(line) }
            // Echo the transcript dropped is not sent on either.
            if let kept = transcript.lines.last(where: { $0.stem == line.stem && $0.start == line.start }) {
                assist?.send(["type": "line", "stem": kept.stem.rawValue, "speaker": kept.label, "text": kept.text,
                              "start": kept.start, "end": kept.end])
            }
            updateTalk()
        } else {
            transcript.volatile[line.stem] = line
        }
        refreshLines()
    }

    private func updateTalk() {
        guard coach != nil || assist != nil else { return }
        let stats = TalkStats.compute(transcript.lines)
        assistView.talk = stats
        if let card = coach?.check(stats) {
            assistView.upsert(card)
            onCard?(card)
        }
    }

    private func refreshLines() {
        // The whole call (the list is lazy), each line keyed by side and time
        // so a picked line stays picked as others arrive.
        var seen = Set<String>()
        var shown = transcript.lines.map { line in
            var id = "\(line.stem.rawValue)-\(line.start)"
            while seen.contains(id) { id += "+" }
            seen.insert(id)
            return LiveNotesViewModel.Line(id: id, speaker: line.label, text: line.text, mine: line.stem == .mic,
                                           inProgress: false, start: line.start)
        }
        for stem in [LiveStem.system, .mic] {
            if let line = transcript.shownVolatile(stem) {
                shown.append(.init(id: "volatile-\(stem.rawValue)", speaker: stem.speaker, text: line.text,
                                   mine: stem == .mic, inProgress: true, start: line.start))
            }
        }
        view.lines = shown
        view.selected.formIntersection(seen)
    }

    private var wordCount: Int { transcript.lines.reduce(0) { $0 + LiveTranscript.words($1.text).count } }

    private func updateNotes() {
        guard !updating, let model else { return }
        let words = wordCount
        guard words >= 8, words != wordsAtLastUpdate else { return }
        updating = true
        wordsAtLastUpdate = words
        let text = transcript.text(maxWords: model.transcriptWords)
        let previous = notes
        Task { @MainActor in
            do {
                let fresh = try await model.notes(previous: previous, transcript: text)
                let all = (notes ?? LiveNotesSections()).merged(with: fresh)
                notes = all
                view.notes = all
                view.status = "Notes updated \(Self.clock.string(from: Date())) · \(model.name)"
                save()
            } catch {
                view.status = "Notes update failed (\(model.name)): \(error)"
                Log.shared.write("live notes: update failed: \(error)")
            }
            updating = false
        }
    }

    /// The parts of the call: the model looks again at the part still open
    /// (from its start, at most what it can carry) once enough more is said.
    private func updateTopics() {
        guard !updatingTopics, let model else { return }
        let words = wordCount
        guard words >= 120, words - wordsAtLastTopics >= 120 else { return }
        updatingTopics = true
        wordsAtLastTopics = words
        let open = topics.last
        let lines = transcript.lines.filter { $0.start >= (open?.start ?? 0) - 1 }
            .map { "[\(LiveTranscript.stamp($0.start))] \($0.label): \($0.text)" }
        let text = FallbackNotesModel.lastWords(lines.joined(separator: "\n"), model.transcriptWords)
        let now = callTime
        Task { @MainActor in
            do {
                let reply = try await model.reply(instructions: TopicsPrompt.instructions,
                                                  text: TopicsPrompt.request(open: open, transcript: text))
                topics = CallTopics.merged(topics, fresh: TopicsPrompt.parse(reply), now: now)
                view.topics = topics
                save()
            } catch {
                Log.shared.write("live notes: parts update failed: \(error)")
            }
            updatingTopics = false
        }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// Stop listening, write the last notes, then call `completion` (on the
    /// main thread). Gives up waiting after `timeout` seconds so the recording
    /// is never held back for long.
    func finish(timeout: Double = 30, completion: @escaping () -> Void) {
        timer?.invalidate()
        timer = nil
        hotkey?.unregister()
        hotkey = nil
        keys.forEach { $0.unregister() }
        keys.removeAll()
        router.set(.mic, nil)
        router.set(.system, nil)
        var done = false
        let complete = { [weak self] in
            guard !done else { return }
            done = true
            self?.assist?.stop()  // after the last lines, so they reach it too
            self?.save()
            self?.panel?.close()
            completion()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            if !done { Log.shared.write("live notes: gave up waiting for the last notes after \(Int(timeout)) s") }
            complete()
        }
        Task { @MainActor in
            for transcriber in transcribers { await transcriber.finish() }
            if let model, !transcript.lines.isEmpty, !done {
                do {
                    let fresh = try await model.notes(previous: notes,
                                                      transcript: transcript.text(maxWords: model.transcriptWords))
                    let all = (notes ?? LiveNotesSections()).merged(with: fresh)
                    notes = all
                    view.notes = all
                } catch {
                    Log.shared.write("live notes: last update failed: \(error)")
                }
            }
            view.status = "Call ended · notes saved with the recording"
            complete()
        }
    }

    /// live-notes.md in the session folder: notes, then the transcript.
    private func save() {
        guard !transcript.lines.isEmpty || notes != nil else { return }
        let stamp = ISO8601DateFormatter().string(from: started)
        var text = "# Live notes\n\nTaken during the call (started \(stamp)) by \(model?.name ?? "no notes model"). "
            + "Machine-made: check against the recording.\n\n"
        text += (notes ?? LiveNotesSections()).markdown
        text += "\n## Transcript\n\nYou = this Mac's microphone, Them = the call. "
            + "\(transcript.echoDropped) echoed lines left out.\n\n"
        text += transcriptWithParts + "\n"
        if !assistView.talk.isEmpty {
            text += "\n## Talk time\n\n" + assistView.talk.summary + "\n"
        }
        let found = assistView.cards.filter { !$0.isLooking }
        if !found.isEmpty {
            text += "\n## Coach and assist\n\nCards shown during the call, follow-ups under their answer.\n\n"
            func entry(_ card: AssistCard, _ indent: String) -> String {
                let when = card.at.map { "[\(LiveTranscript.stamp($0))] " } ?? ""
                var line = "\(indent)- \(when)(\(card.parent == nil ? card.kind.label : "Follow-up")) **\(card.title)**"
                if let body = card.body, !body.isEmpty { line += " — " + body.replacingOccurrences(of: "\n", with: " ") }
                if let source = card.source, !source.isEmpty { line += " (\(source))" }
                return line + "\n"
            }
            let ids = Set(found.map(\.id))
            for card in found where card.parent.map({ !ids.contains($0) }) ?? true {
                text += entry(card, "")
                for turn in found where turn.parent == card.id { text += entry(turn, "  ") }
            }
        }
        let url = sessionDir.appendingPathComponent(LiveNotesFiles.sessionFile)
        do {
            try text.data(using: .utf8)!.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Log.shared.write("live notes: could not save \(url.path): \(error)")
        }
    }

    var finalNotes: LiveNotesSections? { notes }

    /// What the "meeting finished" window shows, once the recording is saved.
    func summary(recording: URL, sidecar: [String: Any]?) -> MeetingSummary {
        let apps = (sidecar?["apps"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? callApps
        let notesFile = recording.deletingPathExtension().appendingPathExtension("notes.md")
        return MeetingSummary(title: assistView.title, startedAt: started,
                              duration: (sidecar?["duration_seconds"] as? Double) ?? Date().timeIntervalSince(started),
                              apps: apps, workspace: assistView.workspace, notes: notes ?? LiveNotesSections(),
                              talk: TalkStats.compute(transcript.lines), recording: recording,
                              notesFile: FileManager.default.fileExists(atPath: notesFile.path) ? notesFile : nil,
                              transcript: transcript.text(), addedSteps: addedSteps)
    }
    var transcriptText: String { transcript.text() }

    /// The transcript with a "### [mm:ss] Part" heading where each part starts.
    private var transcriptWithParts: String {
        var out: [String] = []
        var part = -1
        for line in transcript.lines {
            if let index = CallTopics.index(at: line.start, in: topics), index != part {
                part = index
                out.append((out.isEmpty ? "" : "\n") + "### [\(LiveTranscript.stamp(topics[index].start))] "
                    + topics[index].title + "\n")
            }
            out.append("[\(LiveTranscript.stamp(line.start))] \(line.label): \(line.text)")
        }
        return out.joined(separator: "\n")
    }
}

/// Control-Option-<key> anywhere, even with the call app in front. Carbon
/// hot keys, so they need no Accessibility access. H asks the assist for
/// help; N starts the next call.
final class GlobalHotkey {
    static let help: (key: Int, id: UInt32) = (kVK_ANSI_H, 1)
    static let nextCall: (key: Int, id: UInt32) = (kVK_ANSI_N, 2)
    static let moment: (key: Int, id: UInt32) = (kVK_ANSI_M, 3)
    static let aside: (key: Int, id: UInt32) = (kVK_ANSI_A, 4)

    private static var registry: [UInt32: GlobalHotkey] = [:]
    private static var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private let id: UInt32
    private let action: () -> Void

    init?(_ which: (key: Int, id: UInt32), action: @escaping () -> Void) {
        id = which.id
        self.action = action
        if Self.handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            guard InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var pressed = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
                let id = pressed.id
                DispatchQueue.main.async { GlobalHotkey.registry[id]?.action() }
                return noErr
            }, 1, &spec, nil, &Self.handler) == noErr else { return nil }
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D43_4150), id: which.id)  // "MCAP"
        guard RegisterEventHotKey(UInt32(which.key), UInt32(controlKey | optionKey), hotKeyID,
                                  GetApplicationEventTarget(), 0, &hotKey) == noErr else {
            Log.shared.write("hot key \(which.id) is taken by another app; use the button instead")
            return nil
        }
        Self.registry[which.id] = self
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        if Self.registry[id] === self { Self.registry[id] = nil }
    }
}
