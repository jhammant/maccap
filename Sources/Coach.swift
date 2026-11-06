import Foundation

// Talk time and a light-touch coach, from the live transcript: who has done
// how much of the talking, your longest unbroken stretch, who asks the
// questions, and a nudge when the balance tips too far. Measured from the
// transcribed lines (echo already removed), so it is a guide, not a stopwatch.

struct TalkStats: Equatable {
    struct Person: Equatable {
        var name: String
        var seconds: Double
        var share: Double
        var mine: Bool
    }

    /// You first, then everyone else by talk time.
    var people: [Person] = []
    var yourShare = 0.0
    /// Your share of the talking in the last `window` seconds; nil until
    /// there is a minute of talk in it.
    var yourRecentShare: Double?
    var yourQuestions = 0
    var theirQuestions = 0
    /// How long you have been talking without the other side taking a turn,
    /// if you are talking now.
    var yourRun = 0.0
    var longestRun = 0.0
    /// When the latest line ended, in seconds from the start.
    var elapsed = 0.0
    /// Seconds since your last question.
    var sinceYourQuestion = 0.0

    var isEmpty: Bool { people.isEmpty }

    /// A reply of a few words ("mm", "right, yes") doesn't end your turn.
    static let backchannelWords = 3
    /// A line longer than this is counted as this long (a transcriber that
    /// merged a long stretch would otherwise swamp the share).
    static let maxLineSeconds = 30.0
    /// Silence longer than this ends your turn.
    static let turnGap = 4.0

    static func compute(_ lines: [LiveLine], window: Double = 300) -> TalkStats {
        var stats = TalkStats()
        guard !lines.isEmpty else { return stats }
        var seconds: [String: Double] = [:]
        var mine: [String: Bool] = [:]
        var recentYou = 0.0, recentAll = 0.0
        let end = lines.map(\.end).max() ?? 0
        var runStart: Double?
        var runEnd = 0.0
        var lastEnd = 0.0  // anyone: a gap is silence, not their short reply
        var lastQuestion = 0.0
        for line in lines {
            let length = min(max(0, line.end - line.start), maxLineSeconds)
            seconds[line.label, default: 0] += length
            mine[line.label] = line.stem == .mic
            let recent = max(0, min(line.end, line.start + length) - max(line.start, end - window))
            recentAll += recent
            if line.stem == .mic {
                recentYou += recent
                if line.text.contains("?") {
                    stats.yourQuestions += 1
                    lastQuestion = line.end
                }
                if let start = runStart, line.start - lastEnd <= turnGap {
                    runStart = start
                } else {
                    runStart = line.start
                }
                runEnd = max(runEnd, line.end)
                stats.longestRun = max(stats.longestRun, runEnd - (runStart ?? line.start))
            } else {
                if line.text.contains("?") { stats.theirQuestions += 1 }
                if LiveTranscript.words(line.text).count > backchannelWords { runStart = nil }
            }
            lastEnd = max(lastEnd, line.end)
        }
        let total = seconds.values.reduce(0, +)
        guard total > 0 else { return stats }
        stats.people = seconds.map { Person(name: $0.key, seconds: $0.value, share: $0.value / total,
                                             mine: mine[$0.key] ?? false) }
            .sorted { ($0.mine ? 0 : 1, -$0.seconds, $0.name) < ($1.mine ? 0 : 1, -$1.seconds, $1.name) }
        stats.yourShare = stats.people.filter(\.mine).reduce(0) { $0 + $1.share }
        stats.yourRecentShare = recentAll >= 60 ? recentYou / recentAll : nil
        stats.elapsed = end
        if let start = runStart, end - runEnd <= turnGap { stats.yourRun = runEnd - start }
        stats.sinceYourQuestion = end - lastQuestion
        return stats
    }

    /// Plain text for the saved notes.
    var summary: String {
        let shares = people.map { "\($0.name) \(Int(($0.share * 100).rounded()))% (\(LiveTranscript.stamp($0.seconds)))" }
        return shares.joined(separator: ", ")
            + ". Questions: you \(yourQuestions), others \(theirQuestions). "
            + "Your longest stretch: \(LiveTranscript.stamp(longestRun))."
    }
}

/// Nudges during the call, as cards. Each kind at most once every
/// `repeatAfter` seconds, and no more than one every `spacing` seconds, so it
/// helps rather than nags.
struct Coach {
    var talkShare = 0.65
    var monologueSeconds = 90.0
    var questionGap = 480.0
    var repeatAfter = 300.0
    var spacing = 120.0

    private var lastFired: [String: Double] = [:]
    private var lastAny = -Double.infinity
    private var count = 0

    init(talkShare: Double? = nil, monologueSeconds: Double? = nil) {
        if let talkShare { self.talkShare = talkShare }
        if let monologueSeconds { self.monologueSeconds = monologueSeconds }
    }

    mutating func check(_ stats: TalkStats) -> AssistCard? {
        let now = stats.elapsed
        guard now - lastAny >= spacing else { return nil }
        var due: [(rule: String, title: String, body: String)] = []
        if stats.yourRun >= monologueSeconds {
            due.append(("monologue", "You've been talking for \(LiveTranscript.stamp(stats.yourRun)) without a break",
                        "Pause and check they're still with you."))
        }
        if let recent = stats.yourRecentShare, recent >= talkShare {
            due.append(("share", "You've done \(Int((recent * 100).rounded()))% of the talking in the last 5 minutes",
                        "Ask a question and let them talk."))
        }
        if now >= questionGap, stats.sinceYourQuestion >= questionGap {
            due.append(("questions", "No questions from you in \(Int(questionGap / 60)) minutes",
                        "Ask what matters most to them."))
        }
        guard let nudge = due.first(where: { now - (lastFired[$0.rule] ?? -.infinity) >= repeatAfter })
        else { return nil }
        lastFired[nudge.rule] = now
        lastAny = now
        count += 1
        return AssistCard(id: "coach-\(count)", kind: .coach, title: nudge.title, body: nudge.body, source: "coach",
                          at: now, state: .ready)
    }
}
