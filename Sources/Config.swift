import Foundation

/// Where MacCap keeps its files. Everything lives under one home folder
/// (`~/.maccap`, or `MACCAP_HOME`), so tests and other users never collide.
struct MacCapPaths {
    let home: URL
    let audio: URL
    let sessions: URL
    let log: URL
    let config: URL
    let state: URL

    static func resolve(config: MacCapConfig? = nil) -> MacCapPaths {
        let env = ProcessInfo.processInfo.environment
        let home: URL
        if let override = env["MACCAP_HOME"], !override.isEmpty {
            home = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".maccap", isDirectory: true)
        }
        let audio: URL
        if let dir = config?.audioDir, !dir.isEmpty {
            audio = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            audio = home.appendingPathComponent("audio", isDirectory: true)
        }
        return MacCapPaths(
            home: home,
            audio: audio,
            sessions: home.appendingPathComponent("sessions", isDirectory: true),
            log: home.appendingPathComponent("maccap.log"),
            config: home.appendingPathComponent("config.json"),
            state: home.appendingPathComponent("state.json")
        )
    }

    /// Creates the folders owner-only (0700).
    func ensure() throws {
        for dir in [home, audio, sessions] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
    }
}

/// Optional overrides read from `config.json`. Every field may be left out.
struct MacCapConfig: Codable {
    var audioDir: String?
    /// Bundle-ID prefixes or process names that count as a call when they use
    /// the microphone. Replaces the default list when present.
    var allowlist: [String]?
    /// Added to the default list instead of replacing it.
    var extraAllowlist: [String]?
    var startAfterSeconds: Double?
    var stopAfterQuietSeconds: Double?
    var pollSeconds: Double?
    /// macOS 26+: tap only the call apps instead of all system audio. Off by
    /// default until it has been proven on a real call for every app in use.
    var narrowTapToCallApps: Bool?
    var ffmpegPath: String?
    /// The live-notes window during a recording (macOS 26+). On by default.
    var liveNotes: Bool?
    /// Transcription language for live notes, e.g. "en_GB". Default: the Mac's.
    var liveNotesLocale: String?
    /// An OpenAI-compatible endpoint for the notes, e.g. LM Studio's
    /// "http://localhost:1234/v1". Unset: Apple's on-device model.
    var notesModelURL: String?
    var notesModel: String?
    /// Environment variable holding the endpoint's API key, if it needs one.
    var notesModelAPIKeyEnv: String?
    var notesIntervalSeconds: Double?
    /// A program that helps during the call (absolute path, then arguments).
    /// It reads the call as JSON lines on stdin and answers with cards on
    /// stdout; see "Call assist" in the README. Unset: no assist.
    var assistCommand: [String]?
    /// Control-Option-H asks the assist for help with what was just said.
    var assistHotkey: Bool?
    /// After a call: a program that takes the ticked next steps (the meeting
    /// as JSON on stdin; see "Meeting finished" in the README).
    var followupCommand: [String]?
    /// The "meeting finished" window after a call with live notes. On by default.
    var meetingFinished: Bool?
    /// After a call: a program that rewrites the next steps from the whole
    /// transcript (JSON in, JSON out; see "Meeting finished" in the README).
    var finalNotesCommand: [String]?
    /// Things you say that mark a moment by themselves ("action point",
    /// "I'll follow up"...). [] turns it off.
    var momentPhrases: [String]?
    /// Talk time and nudges during the call. On by default.
    var coach: Bool?
    /// Nudge when you have done this share of the last 5 minutes' talking.
    var coachTalkShare: Double?
    /// Nudge when you have talked this long without a break.
    var coachMonologueSeconds: Double?
    /// What "Copy consent message" puts on the clipboard, to paste into the
    /// call's chat or say out loud before recording.
    var consentMessage: String?

    enum CodingKeys: String, CodingKey {
        case audioDir = "audio_dir"
        case allowlist
        case extraAllowlist = "extra_allowlist"
        case startAfterSeconds = "start_after_seconds"
        case stopAfterQuietSeconds = "stop_after_quiet_seconds"
        case pollSeconds = "poll_seconds"
        case narrowTapToCallApps = "narrow_tap_to_call_apps"
        case ffmpegPath = "ffmpeg_path"
        case liveNotes = "live_notes"
        case liveNotesLocale = "live_notes_locale"
        case notesModelURL = "notes_model_url"
        case notesModel = "notes_model"
        case notesModelAPIKeyEnv = "notes_model_api_key_env"
        case notesIntervalSeconds = "notes_interval_seconds"
        case assistCommand = "assist_command"
        case assistHotkey = "assist_hotkey"
        case followupCommand = "followup_command"
        case meetingFinished = "meeting_finished"
        case finalNotesCommand = "final_notes_command"
        case momentPhrases = "moment_phrases"
        case coach
        case coachTalkShare = "coach_talk_share"
        case coachMonologueSeconds = "coach_monologue_seconds"
        case consentMessage = "consent_message"
    }

    static let defaultAllowlist: [String] = [
        "com.google.Chrome",            // Chrome and its helpers
        "company.thebrowser.Browser",   // Arc
        "com.microsoft.edgemac",        // Edge
        "com.brave.Browser",            // Brave
        "com.apple.Safari",
        "com.apple.WebKit",             // Safari's GPU/WebContent processes capture the mic
        "org.mozilla.firefox",
        "us.zoom.xos",                  // Zoom
        "com.microsoft.teams",          // Teams classic and teams2
        "com.tinyspeck.slackmacgap",    // Slack huddles
        "com.apple.FaceTime",
        "com.apple.avconferenced", "avconferenced",   // FaceTime audio daemon
        "com.apple.TelephonyUtilities", "callservicesd",   // iPhone calls answered on the Mac (callservicesd)
        "com.webex", "com.cisco.webex", "Cisco-Systems.Spark",
        "net.whatsapp.WhatsApp", "desktop.WhatsApp", "WhatsApp",
        "com.hnc.Discord",
    ]

    var effectiveAllowlist: [String] {
        (allowlist ?? Self.defaultAllowlist) + (extraAllowlist ?? [])
    }
    var startAfter: Double { startAfterSeconds ?? 4 }
    var stopAfterQuiet: Double { stopAfterQuietSeconds ?? 45 }
    var poll: Double { pollSeconds ?? 2 }
    var liveNotesEnabled: Bool { liveNotes ?? true }
    var notesInterval: Double { max(15, notesIntervalSeconds ?? 60) }
    var coachEnabled: Bool { coach ?? true }
    static let defaultMomentPhrases = [
        "action point", "action item", "let's note", "note that down", "make a note", "i'll follow up",
        "we'll follow up", "i'll send you", "i'll send over", "i'll get back to you", "we'll get back to you",
        "next step is", "i'll put that", "let me take that away",
    ]
    var phrases: [String] { (momentPhrases ?? Self.defaultMomentPhrases).map { $0.lowercased() } }
    var meetingFinishedEnabled: Bool { meetingFinished ?? true }
    static let defaultConsentMessage = "Before we start: I'd like to record this call so I can take notes. "
        + "The recording stays on my Mac. Is everyone OK with that?"
    var consent: String {
        let message = consentMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return message.isEmpty ? Self.defaultConsentMessage : message
    }
    var finalNotes: [String]? {
        guard let command = finalNotesCommand, let program = command.first, program.hasPrefix("/") else { return nil }
        return command
    }
    var followup: [String]? {
        guard let command = followupCommand, let program = command.first, program.hasPrefix("/") else { return nil }
        return command
    }
    var assist: [String]? {
        guard let command = assistCommand, let program = command.first, program.hasPrefix("/") else { return nil }
        return command
    }

    static func load(from url: URL) -> MacCapConfig {
        guard let data = try? Data(contentsOf: url) else { return MacCapConfig() }
        do {
            return try JSONDecoder().decode(MacCapConfig.self, from: data)
        } catch {
            Log.shared.write("config: \(url.path) unreadable (\(error)); using defaults")
            return MacCapConfig()
        }
    }

    /// ffmpeg is not on PATH for apps launched from Finder, so look in the
    /// usual places too.
    func resolveFFmpeg(tool: String = "ffmpeg") -> String? {
        if tool == "ffmpeg", let ffmpegPath, FileManager.default.isExecutableFile(atPath: ffmpegPath) {
            return ffmpegPath
        }
        if tool == "ffprobe", let ffmpegPath {
            let probe = (ffmpegPath as NSString).deletingLastPathComponent + "/ffprobe"
            if FileManager.default.isExecutableFile(atPath: probe) { return probe }
        }
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        for dir in dirs {
            let candidate = dir + "/" + tool
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

/// Small persisted UI state (auto mode paused or not).
struct MacCapState: Codable {
    var autoPaused = false
    /// The System Audio Recording prompt has been raised once (at launch,
    /// so it is never first seen in the middle of a call).
    var systemAudioAsked = false
    /// Open the live-notes window when a recording starts.
    var showLiveNotes = true
    /// Where the app was when it was made a login item, so a moved app
    /// registers again from its new place.
    var loginItemPath: String?
    /// Let screenshots and screen sharing see MacCap's windows (normally hidden).
    var visibleToSharing = false
    /// The person using this Mac agreed, at first launch, to record only
    /// people who have said yes. Nothing is recorded until they have.
    var consentAccepted = false

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoPaused = try container.decodeIfPresent(Bool.self, forKey: .autoPaused) ?? false
        systemAudioAsked = try container.decodeIfPresent(Bool.self, forKey: .systemAudioAsked) ?? false
        showLiveNotes = try container.decodeIfPresent(Bool.self, forKey: .showLiveNotes) ?? true
        loginItemPath = try container.decodeIfPresent(String.self, forKey: .loginItemPath)
        visibleToSharing = try container.decodeIfPresent(Bool.self, forKey: .visibleToSharing) ?? false
        consentAccepted = try container.decodeIfPresent(Bool.self, forKey: .consentAccepted) ?? false
    }

    static func load(from url: URL) -> MacCapState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(MacCapState.self, from: data) else { return MacCapState() }
        return state
    }

    func save(to url: URL) {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
    }
}

/// Append-only log at `~/.maccap/maccap.log`, mirrored to stderr.
final class Log {
    static let shared = Log()
    private let queue = DispatchQueue(label: "maccap.log")
    private var handle: FileHandle?
    private let stamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = .current
        return formatter
    }()

    func open(at url: URL) {
        queue.sync {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil,
                                               attributes: [.posixPermissions: 0o600])
            }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        }
    }

    func write(_ message: String) {
        let line = "\(stamp.string(from: Date())) [\(getpid())] \(message)\n"
        queue.async { [weak self] in
            FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
            if let data = line.data(using: .utf8) { try? self?.handle?.write(contentsOf: data) }
        }
    }

    func flush() { queue.sync { try? handle?.synchronize() } }
}

enum Clock {
    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    /// "YYYYMMDD HHMMSS" in local time, the Voice Memos naming style.
    static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd HHmmss"
        return formatter.string(from: date)
    }

    static func newSessionID() -> String {
        String(format: "%08x", UInt32.random(in: 0...UInt32.max))
    }
}
