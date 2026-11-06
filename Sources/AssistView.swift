import AppKit
import SwiftUI

// The Assist tab of the live-notes window: a map of what the call brought
// up, the cards themselves, and the help bar. Each kind of card has its own
// symbol and colour everywhere it appears.

struct AssistBadge: View {
    var kind: AssistKind
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(kind.color.gradient, in: RoundedRectangle(cornerRadius: size * 0.27))
    }
}

struct AssistChip: View {
    var text: String
    var tint: Color? = nil

    var body: some View {
        Text(text)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .foregroundStyle(tint ?? .secondary)
            .background((tint ?? .secondary).opacity(0.14), in: Capsule())
    }
}

/// The call in the middle of the left edge, a line out to each of the newest
/// things it brought up, in that thing's colour. Lines still being looked up
/// flow.
struct CallMap: View {
    var cards: [AssistCard]
    var onSelect: (String) -> Void = { _ in }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let hub = CGPoint(x: 34, y: height / 2)
            let nodeX = min(width * 0.36, 130)
            let rows = rowPositions(count: cards.count, height: height)
            let looking = cards.contains { $0.isLooking }

            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !looking)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate * 20
                Canvas { canvas, _ in
                    for (index, card) in cards.enumerated() {
                        let start = CGPoint(x: hub.x + 24, y: hub.y)
                        let end = CGPoint(x: nodeX - 4, y: rows[index])
                        var path = Path()
                        path.move(to: start)
                        path.addCurve(to: end, control1: CGPoint(x: (start.x + end.x) / 2, y: start.y),
                                      control2: CGPoint(x: (start.x + end.x) / 2, y: end.y))
                        let style = card.isLooking
                            ? StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 5], dashPhase: -phase)
                            : StrokeStyle(lineWidth: 2, lineCap: .round)
                        let opacity = card.state == .failed ? 0.25 : 0.7
                        canvas.stroke(path, with: .color(card.kind.color.opacity(opacity)), style: style)
                    }
                }
            }

            Image(systemName: "waveform")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Color.accentColor.gradient, in: Circle())
                .overlay(alignment: .bottom) {
                    Text("This call").font(.caption2).foregroundStyle(.secondary).fixedSize().offset(y: 16)
                }
                .position(hub)

            if cards.isEmpty {
                Text("Listening for people, questions and what's on screen")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(width: max(0, width - 90), alignment: .leading)
                    .position(x: 80 + (width - 90) / 2, y: hub.y)
            }

            ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                HStack(spacing: 6) {
                    AssistBadge(kind: card.kind, size: 22)
                    Text(card.title).font(.caption.weight(.medium)).lineLimit(1)
                    if card.isLooking { ProgressView().controlSize(.mini) }
                    Spacer(minLength: 0)
                }
                .frame(width: max(0, width - nodeX), alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { onSelect(card.id) }
                .help([card.title, card.body].compactMap { $0 }.joined(separator: "\n\n") + "\n\nClick to open")
                .position(x: nodeX + (width - nodeX) / 2, y: rows[index])
            }
        }
    }

    private func rowPositions(count: Int, height: CGFloat) -> [CGFloat] {
        guard count > 1 else { return [height / 2] }
        let top: CGFloat = 14, bottom = height - 14
        return (0..<count).map { top + CGFloat($0) * (bottom - top) / CGFloat(count - 1) }
    }
}

/// Who has done the talking: your share as a ring (green while balanced,
/// orange, then red past the coach's limit), everyone as one bar, and the
/// numbers behind it.
struct TalkPanel: View {
    var stats: TalkStats
    var limit = 0.65

    static let others: [Color] = [.orange, .pink, .teal, .purple, .brown, .yellow]

    private func color(_ index: Int, _ person: TalkStats.Person) -> Color {
        person.mine ? .accentColor : Self.others[(index - 1 + Self.others.count) % Self.others.count]
    }

    private var zone: Color {
        stats.yourShare >= limit ? .red : stats.yourShare >= limit - 0.15 ? .orange : .green
    }

    private func percent(_ share: Double) -> String { "\(Int((share * 100).rounded()))%" }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.1), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: stats.yourShare)
                    .stroke(zone.gradient, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: -2) {
                    Text(percent(stats.yourShare)).font(.system(size: 15, weight: .bold)).monospacedDigit()
                    Text("you").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 58, height: 58)
            .animation(.snappy, value: stats.yourShare)
            VStack(alignment: .leading, spacing: 5) {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(Array(stats.people.enumerated()), id: \.element.name) { index, person in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(color(index, person).gradient)
                                .frame(width: max(3, (geo.size.width - CGFloat(stats.people.count) * 2) * person.share))
                        }
                    }
                }
                .frame(height: 10)
                .animation(.snappy, value: stats.people)
                HStack(spacing: 8) {
                    ForEach(Array(stats.people.prefix(4).enumerated()), id: \.element.name) { index, person in
                        HStack(spacing: 3) {
                            Circle().fill(color(index, person)).frame(width: 7, height: 7)
                            Text("\(person.mine ? "You" : person.name) \(percent(person.share))")
                                .font(.caption).lineLimit(1)
                        }
                    }
                }
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private var details: String {
        var parts: [String] = []
        if let recent = stats.yourRecentShare { parts.append("last 5 min \(percent(recent))") }
        parts.append("questions: you \(stats.yourQuestions), them \(stats.theirQuestions)")
        if stats.longestRun >= 30 { parts.append("longest stretch \(LiveTranscript.stamp(stats.longestRun))") }
        return parts.joined(separator: " · ")
    }
}

struct AssistCardView: View {
    var card: AssistCard
    /// Follow-ups to this answer, oldest first.
    var thread: [AssistCard] = []
    var highlighted = false
    var focused = false
    /// The helper is running, so an answer can be followed up.
    var canFollowUp = false
    var onNextCall: () -> Void = {}
    var onEdit: (String, String) -> Void = { _, _ in }
    var onRetype: (String) -> Void = { _ in }
    var onRemove: (String) -> Void = { _ in }
    /// A follow-up question to this answer's thread.
    var onFollowUp: (String) -> Void = { _ in }
    @State private var open = false
    @State private var editing = false
    @State private var draft = ""
    @State private var askingMore = false
    @State private var question = ""
    @FocusState private var questionFocused: Bool

    /// Things you added yourself (typed, said, marked) can be changed.
    private var mine: Bool { ["action-", "note-", "moment-"].contains { card.id.hasPrefix($0) } }

    /// Answers are always shown whole; other cards open on a click.
    private var whole: Bool { card.kind == .answer }

    private var long: Bool {
        guard let body = card.body else { return false }
        return body.count > 220 || body.split(separator: "\n").count > 5
    }

    private var hasMore: Bool {
        (card.detail?.isEmpty == false) || card.link != nil || (!whole && long)
    }

    /// An answer can take a follow-up once it, and the follow-ups so far, are in.
    private var followable: Bool {
        canFollowUp && card.kind == .answer && card.body?.isEmpty == false
            && !card.isLooking && !thread.contains { $0.isLooking }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                AssistBadge(kind: card.kind)
                VStack(alignment: .leading, spacing: 3) {
                    if editing {
                        TextField("", text: $draft, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !text.isEmpty { onEdit(card.id, text) }
                                editing = false
                            }
                            .onExitCommand { editing = false }
                    } else {
                        Text(card.title).font(.headline).lineLimit(2).textSelection(.enabled)
                    }
                    HStack(spacing: 4) {
                        AssistChip(text: card.kind.label, tint: card.kind.color)
                        if let at = card.at { AssistChip(text: LiveTranscript.stamp(at)) }
                        ForEach(Array((card.chips ?? []).prefix(3).enumerated()), id: \.offset) { _, chip in
                            AssistChip(text: chip)
                        }
                    }
                }
                Spacer(minLength: 0)
                if card.isLooking { ProgressView().controlSize(.small) }
                if card.state == .failed {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                }
                if hasMore {
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            if let quote = card.quote, !quote.isEmpty {
                Text("“\(quote)”").font(.callout.italic()).foregroundStyle(.secondary).lineLimit(2)
            }
            if let body = card.body, !body.isEmpty {
                MarkdownText(text: body, lineLimit: open || whole ? nil : 5).font(.callout).textSelection(.enabled)
            } else if card.isLooking {
                Text("Looking…").font(.callout).foregroundStyle(.tertiary)
            }
            if open, let detail = card.detail, !detail.isEmpty {
                Divider()
                MarkdownText(text: detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                if let source = card.source, !source.isEmpty {
                    Label(source, systemImage: "link").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if open, let link = card.link, let url = URL(string: link) {
                    Button("Open") { NSWorkspace.shared.open(url) }.controlSize(.small)
                }
                if thread.isEmpty { followUpButton }
            }
            ForEach(thread) { turn in
                Divider()
                FollowUpView(turn: turn, tint: card.kind.color)
                if turn.id == thread.last?.id {
                    HStack(spacing: 8) {
                        if let source = turn.source, !source.isEmpty {
                            Label(source, systemImage: "link").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        followUpButton
                    }
                }
            }
            if askingMore {
                TextField("Follow up on this…", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .focused($questionFocused)
                    .onAppear { questionFocused = true }
                    .onSubmit {
                        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        question = ""
                        askingMore = false
                        onFollowUp(text)
                    }
                    .onExitCommand { askingMore = false }
            }
            if card.action == "next_call" {
                Button(action: onNextCall) { Label("Start next call", systemImage: "forward.end.fill") }
                    .buttonStyle(HelpButtonStyle())
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { if hasMore && !editing { withAnimation(.snappy) { open.toggle() } } }
        .contextMenu {
            if mine {
                Button("Edit") {
                    draft = card.title
                    editing = true
                }
                Button(card.kind == .note ? "Make it an action" : "Make it a note") { onRetype(card.id) }
                Button("Remove", role: .destructive) { onRemove(card.id) }
                Divider()
            }
            Button("Copy") {
                let turns = [[card.title, card.body]] + thread.map { ["**\($0.title)**", $0.body] }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(turns.map { $0.compactMap { $0 }.joined(separator: "\n") }
                                                   .joined(separator: "\n\n"), forType: .string)
            }
        }
        .onChange(of: focused) { _, now in if now && hasMore { withAnimation(.snappy) { open = true } } }
        .onChange(of: canFollowUp) { _, now in if !now { askingMore = false } }
        .help(hasMore && !open ? "Click for more" : "")
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(highlighted ? card.kind.color : Color.primary.opacity(0.08), lineWidth: highlighted ? 2 : 1)
        }
    }
}

extension AssistCardView {
    @ViewBuilder
    fileprivate var followUpButton: some View {
        if followable && !askingMore {
            Button { askingMore = true } label: {
                Label("Follow up", systemImage: "arrowshape.turn.up.left")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .font(.caption.weight(.medium))
            .help("Ask more about this answer; the questions and answers so far go with it")
        }
    }
}

/// One follow-up inside its answer's card: the question, then its answer.
struct FollowUpView: View {
    var turn: AssistCard
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "arrow.turn.down.right").font(.caption.weight(.bold)).foregroundStyle(tint)
                Text(turn.title).font(.callout.weight(.semibold)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let at = turn.at { AssistChip(text: LiveTranscript.stamp(at)) }
                if turn.isLooking { ProgressView().controlSize(.small) }
                if turn.state == .failed { Image(systemName: "exclamationmark.circle").foregroundStyle(.red) }
            }
            if let body = turn.body, !body.isEmpty {
                MarkdownText(text: body).font(.callout).textSelection(.enabled)
            } else if turn.isLooking {
                Text("Looking…").font(.callout).foregroundStyle(.tertiary)
            }
        }
    }
}

/// The bottom of the Assist/Coach tab: Help me answer (with a helper), and
/// one box for adding an action, a note, or asking the assist, plus the mic
/// button for saying an action.
struct InputBar: View {
    enum Mode: String, CaseIterable, Identifiable {
        case action = "Action", note = "Note", ask = "Ask"
        var id: String { rawValue }
        var placeholder: String {
            switch self {
            case .action: return "Add an action… (who does what)"
            case .note: return "Add a note…"
            case .ask: return "Ask about this call…"
            }
        }
    }

    var helper: Bool
    var busy: Bool
    var hotkey: Bool
    var aside: Bool
    var onHelp: () -> Void
    var onSubmit: (Mode, String) -> Void
    var onAside: () -> Void
    @State private var mode = Mode.action
    @State private var text = ""

    var body: some View {
        VStack(spacing: 6) {
            if helper {
                Button(action: onHelp) {
                    Label(busy ? "Working on it…" : "Help me answer", systemImage: "lifepreserver.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(HelpButtonStyle())
                .disabled(busy)
                .help("Facts and ideas for what was just said" + (hotkey ? " (Control-Option-H)" : ""))
            }
            HStack(spacing: 6) {
                Menu {
                    ForEach(Mode.allCases.filter { helper || $0 != .ask }) { choice in
                        Button(choice.rawValue) { mode = choice }
                    }
                } label: {
                    Text(mode.rawValue).font(.callout)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                TextField(mode.placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                Button(action: onAside) {
                    Image(systemName: aside ? "stop.circle.fill" : "mic.fill")
                        .foregroundStyle(aside ? Color.red : Color.primary)
                }
                .buttonStyle(.borderless)
                .help(aside ? "Finish the spoken action (Control-Option-A)"
                            : "Say an action (Control-Option-A). Mute yourself in the call first if they shouldn't hear it.")
            }
            if aside {
                Text("Listening for your action… press Control-Option-A or ⏹ to finish")
                    .font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func submit() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        text = ""
        onSubmit(mode, value)
    }
}

/// Always in colour: the window never comes to the front, so a standard
/// prominent button would look greyed out for the whole call.
struct HelpButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HelpButtonBody(configuration: configuration)
    }

    private struct HelpButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.vertical, 7)
                .background(Color.green.gradient, in: RoundedRectangle(cornerRadius: 9))
                .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
        }
    }
}

struct AssistView: View {
    @ObservedObject var model: AssistViewModel
    var helper: Bool
    var hotkey: Bool
    var limit = 0.65
    var onHelp: () -> Void
    var onSubmit: (InputBar.Mode, String) -> Void = { _, _ in }
    var onAside: () -> Void = {}
    var onMoment: () -> Void = {}
    var onNextCall: () -> Void = {}
    var onEdit: (String, String) -> Void = { _, _ in }
    var onRetype: (String) -> Void = { _ in }
    var onRemove: (String) -> Void = { _ in }
    var onChoose: (String?) -> Void = { _ in }
    /// A follow-up: (question, the answer it follows).
    var onFollowUp: (String, String) -> Void = { _, _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if model.choices.isEmpty {
                    Text(model.title ?? "This call").font(.headline).lineLimit(1)
                } else {
                    Menu {
                        ForEach(model.choices) { choice in
                            Button((choice.id == model.chosen ? "✓ " : "") + choice.label) { onChoose(choice.id) }
                        }
                        Divider()
                        Button((model.chosen == nil ? "✓ " : "") + "None of these") { onChoose(nil) }
                    } label: {
                        Text(model.title ?? "Which meeting is this?").font(.headline).lineLimit(1)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("Wrong meeting? Pick the right one")
                }
                if let workspace = model.workspace { AssistChip(text: workspace, tint: .accentColor) }
                Spacer(minLength: 0)
                Button(action: onMoment) { Label("Moment", systemImage: "bookmark.fill") }
                    .controlSize(.small)
                    .help("Mark this moment: it notes the action or point of the last minute (Control-Option-M)")
                Button(action: onNextCall) { Label("Next call", systemImage: "forward.end.fill") }
                    .controlSize(.small)
                    .help("Save this call and start a new recording (Control-Option-N)")
            }
            if !model.status.isEmpty {
                Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if !model.talk.isEmpty { TalkPanel(stats: model.talk, limit: limit) }
            CallMap(cards: Array(model.cards.filter { $0.pinned != true }.suffix(5))) { model.focused = $0 }
                .frame(height: 140)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.ordered) { card in
                            AssistCardView(card: card, thread: model.thread(card.id),
                                           highlighted: card.id == model.highlighted,
                                           focused: card.id == model.focused, canFollowUp: helper && model.running,
                                           onNextCall: onNextCall, onEdit: onEdit, onRetype: onRetype,
                                           onRemove: onRemove, onFollowUp: { onFollowUp($0, card.id) })
                                .id(card.id)
                        }
                    }
                }
                .onChange(of: model.focused) { _, id in
                    if let id { withAnimation(.snappy) { proxy.scrollTo(id, anchor: .top) } }
                }
            }
            InputBar(helper: helper && model.running, busy: !model.waiting.isEmpty, hotkey: hotkey, aside: model.aside,
                     onHelp: onHelp, onSubmit: onSubmit, onAside: onAside)
        }
        .padding(12)
    }
}

/// The whole window: Assist (or Coach, without a helper) and Notes as two
/// tabs, else the notes alone.
struct CallPanelView: View {
    enum Tab { case assist, notes }

    @ObservedObject var notes: LiveNotesViewModel
    @ObservedObject var assist: AssistViewModel
    var assistEnabled: Bool
    /// A helper program is set up (cards from it, and the help bar).
    var helper = true
    var hotkey: Bool
    var limit = 0.65
    var onHelp: () -> Void = {}
    var onSubmit: (InputBar.Mode, String) -> Void = { _, _ in }
    var onAside: () -> Void = {}
    var onMoment: () -> Void = {}
    var onNextCall: () -> Void = {}
    var onEdit: (String, String) -> Void = { _, _ in }
    var onRetype: (String) -> Void = { _ in }
    var onRemove: (String) -> Void = { _ in }
    var onChoose: (String?) -> Void = { _ in }
    /// Help with lines picked in the transcript: (lines, part title).
    var onHelpWith: (String, String?) -> Void = { _, _ in }
    /// A question about picked lines: (question, lines, part title).
    var onAskAbout: (String, String, String?) -> Void = { _, _, _ in }
    /// A follow-up: (question, the answer it follows).
    var onFollowUp: (String, String) -> Void = { _, _ in }
    @State private var tab = Tab.assist

    /// The transcript; its answers come up in the Assist tab, so it switches there.
    private var notesView: LiveNotesView {
        LiveNotesView(model: notes, helper: helper && assist.running,
                      onHelp: { lines, title in
                          tab = .assist
                          onHelpWith(lines, title)
                      },
                      onAsk: { question, lines, title in
                          tab = .assist
                          onAskAbout(question, lines, title)
                      })
    }

    var body: some View {
        if assistEnabled {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text(helper ? "Assist" : "Coach").tag(Tab.assist)
                    Text("Notes & transcript").tag(Tab.notes)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding([.horizontal, .top], 12)
                switch tab {
                case .assist: AssistView(model: assist, helper: helper, hotkey: hotkey, limit: limit, onHelp: onHelp,
                                         onSubmit: onSubmit, onAside: onAside, onMoment: onMoment,
                                         onNextCall: onNextCall, onEdit: onEdit, onRetype: onRetype,
                                         onRemove: onRemove, onChoose: onChoose, onFollowUp: onFollowUp)
                case .notes: notesView
                }
            }
            .frame(minWidth: 320, minHeight: 480)
        } else {
            notesView
        }
    }
}
