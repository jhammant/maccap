import Foundation

// The parts of a call ("Introductions", "Volumes and pricing", "Next steps"),
// found by the live-notes model as the call goes. Only the part still open is
// looked at again each time, so a long call costs the same as a short one and
// the parts already closed never move. Headings in the transcript, a way to
// pick a whole part, and context for Help and Ask.

struct CallTopic: Equatable {
    /// Seconds from the start of the recording.
    var start: Double
    var title: String
}

enum TopicsPrompt {
    static let instructions = """
        You put headings into the transcript of a live call: you split it into the parts of the conversation, \
        the way a person would (introductions, a demo, volumes and pricing, the rollout, next steps). A new part \
        starts only when the subject really changes, usually after a few minutes, never for a single aside. \
        Each transcript line starts with its time [mm:ss]. Reply with one line per part, oldest first, exactly:
        [mm:ss] Title of two to six words
        where [mm:ss] is the time of the part's first line. Titles name the subject ("EU hosting date", \
        "Priya's volumes"), not "Discussion". No other text.
        """

    /// One update: the part still open (if any) and the transcript from where it starts.
    static func request(open: CallTopic?, transcript: String) -> String {
        var parts: [String] = []
        if let open {
            parts.append("The part under way started at [\(LiveTranscript.stamp(open.start))], titled \"\(open.title)\". "
                + "Keep it (you may improve its title) and add a part only where the subject changed after it.")
        }
        parts.append("Transcript\(open == nil ? "" : " from there"):\n\(transcript)")
        return parts.joined(separator: "\n\n")
    }

    /// "[mm:ss] Title" lines (bullets, bold and "-" or ":" after the time are
    /// allowed); anything else is ignored.
    static func parse(_ reply: String) -> [CallTopic] {
        let pattern = try! NSRegularExpression(pattern: #"^\[?(\d{1,3}):(\d{2})(?::(\d{2}))?\]?\s*[-–—:.]?\s*(.+)$"#)
        var topics: [CallTopic] = []
        for raw in LiveNotesPrompt.stripThinking(reply).components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-*• "))
            let range = NSRange(line.startIndex..., in: line)
            guard let match = pattern.firstMatch(in: line, range: range),
                  let a = Range(match.range(at: 1), in: line), let b = Range(match.range(at: 2), in: line),
                  let t = Range(match.range(at: 4), in: line) else { continue }
            var seconds = Double(Int(line[a])! * 60 + Int(line[b])!)
            if let c = Range(match.range(at: 3), in: line) {  // h:mm:ss
                seconds = Double(Int(line[a])! * 3600 + Int(line[b])! * 60 + Int(line[c])!)
            }
            let title = line[t].trimmingCharacters(in: CharacterSet(charactersIn: "*_\"' ."))
            if !title.isEmpty { topics.append(CallTopic(start: seconds, title: String(title.prefix(60)))) }
        }
        return topics
    }
}

enum CallTopics {
    /// A part shorter than this is an aside, not a part.
    static let shortest: Double = 45

    /// The closed parts kept as they are; the open one and anything after it
    /// from `fresh`. Parts before the open one's start, past `now`, or too
    /// close to the one before are dropped; the first part starts with the call.
    static func merged(_ topics: [CallTopic], fresh: [CallTopic], now: Double) -> [CallTopic] {
        let open = topics.last
        let from = open?.start ?? 0
        var tail = fresh.filter { $0.start >= from - 5 && $0.start <= now + 5 }.sorted { $0.start < $1.start }
        if let open {
            // The model may restate the open part a little off its start, or leave it out.
            if let first = tail.first, first.start < from + shortest {
                tail[0].start = from
            } else {
                tail.insert(open, at: 0)
            }
        }
        var out = Array(topics.dropLast())
        for topic in tail {
            if let last = out.last, topic.start - last.start < shortest { continue }
            out.append(topic)
        }
        if !out.isEmpty { out[0].start = 0 }
        return out
    }

    /// Which part a moment falls in (index into `topics`).
    static func index(at seconds: Double, in topics: [CallTopic]) -> Int? {
        topics.lastIndex { $0.start <= seconds + 0.5 }
    }

    static func listing(_ topics: [CallTopic]) -> String {
        topics.map { "[\(LiveTranscript.stamp($0.start))] \($0.title)" }.joined(separator: "\n")
    }
}
