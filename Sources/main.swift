import AppKit
import AVFoundation
import Foundation

umask(0o077)  // every file MacCap or its ffmpeg child creates is owner-only
setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }
let config = MacCapConfig.load(from: MacCapPaths.resolve().config)
let paths = MacCapPaths.resolve(config: config)
do { try paths.ensure() } catch {
    FileHandle.standardError.write("cannot create \(paths.home.path): \(error)\n".data(using: .utf8)!)
    exit(2)
}
// The self-tests never write to the real log.
Log.shared.open(at: arguments.first == "selftest"
    ? FileManager.default.temporaryDirectory.appendingPathComponent("maccap-selftest.log") : paths.log)

func usage() {
    print("""
    MacCap \(Finalizer.version): records calls on this Mac as a stereo m4a
    (left = your microphone, right = everyone else) with a JSON sidecar.

    Usage:
      MacCap                       run the menu-bar app (records calls automatically)
      MacCap record --seconds N    record N seconds, save, print the file
      MacCap callers               list apps using audio and which count as calls
      MacCap finalize-pending      save sessions left unfinished (crash, power loss)
      MacCap notes FILE.m4a        replay a recording through live notes; print the transcript and notes
             [--help-me] [--ask Q]   then ask the call assist for help, or ask it a question
             [--follow-up Q]         and follow that answer up with another
      MacCap record --seconds N --notes   also take live notes (printed at the end)
      MacCap demo FILE.m4a [--speed X]    play a stereo file (left you, right them) into the live
                                          window, then the meeting-finished window; records nothing
      MacCap selftest              run the built-in tests (no microphone needed)

    Run `record` through the app bundle so macOS asks MacCap, not your terminal,
    for permission:  open -W -n -a MacCap.app --args record --seconds 20
    Files: \(paths.home.path) (config.json, audio/, sessions/, maccap.log)
    """)
}

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

/// Single menu-bar instance per user, so two auto-recorders never race.
func takeMenuLock() -> Bool {
    let fd = open(paths.home.appendingPathComponent("menu.lock").path, O_CREAT | O_RDWR, 0o600)
    return fd >= 0 && flock(fd, LOCK_EX | LOCK_NB) == 0
}

func printNotes(_ notes: LiveNotesSections?) {
    guard let notes, !notes.isEmpty else {
        print("notes: none")
        return
    }
    print(notes.markdown)
}

func printLine(_ line: LiveLine) {
    print("[\(LiveTranscript.stamp(line.start))] \(line.label): \(line.text)")
}

func printCard(_ card: AssistCard) {
    guard !card.isLooking else { return }
    let body = card.body.map { " — " + $0.replacingOccurrences(of: "\n", with: " ") } ?? ""
    let thread = card.parent.map { " (follow-up to \($0))" } ?? ""
    print("card \(card.id)\(thread) [\(card.kind.label)] \(card.title)\(body)" + (card.state == .failed ? " (failed)" : ""))
}

final class RecordCommand: NSObject, NSApplicationDelegate {
    let seconds: Double
    let notes: Bool
    private var live: AnyObject?
    init(seconds: Double, notes: Bool) {
        self.seconds = seconds
        self.notes = notes
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let session: RecordingSession
        do {
            session = try RecordingSession(paths: paths, config: config, trigger: "cli", apps: [])
        } catch {
            print("error: \(error)")
            exit(2)
        }
        session.onAlert = { title, body in print("ALERT: \(title). \(body)") }
        if notes, #available(macOS 26.0, *) {
            let live = LiveNotesController(config: config, originHost: session.originHost, sessionDir: session.dir)
            live.onFinalLine = printLine
            live.attach(to: session)
            live.start(showWindow: false)
            self.live = live
        }
        print("recording \(Int(seconds)) s into \(session.dir.path)")
        session.start {
            DispatchQueue.main.asyncAfter(deadline: .now() + self.seconds) {
                let dir = session.stop(skipped: false)
                if #available(macOS 26.0, *), let live = self.live as? LiveNotesController {
                    live.finish {
                        printNotes(live.finalNotes)
                        self.save(dir)
                    }
                } else {
                    self.save(dir)
                }
            }
        }
    }

    private func save(_ dir: URL) {
        do {
            let url = try Finalizer.finalize(sessionDir: dir, paths: paths, config: config)
            print("saved \(url.path)")
            let sidecar = url.deletingPathExtension().appendingPathExtension("maccap.json")
            if let data = try? Data(contentsOf: sidecar),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let health = json["health"] as? [String: Any] {
                print("health: \(health["verdict"] ?? "?")")
                for stem in ["mic", "system"] {
                    if let stats = health[stem] as? [String: Any] {
                        print("  \(stem): \(stats["status"] ?? "?"), audible \(stats["audible_seconds"] ?? 0) s, "
                            + "rms \(stats["rms_dbfs"] ?? "n/a") dBFS, rates \(stats["sample_rates"] ?? [])")
                    }
                }
            }
            Log.shared.flush()
            exit(0)
        } catch {
            print("finalize failed: \(error)")
            Log.shared.flush()
            exit(3)
        }
    }
}

/// `notes FILE.m4a`: plays a saved MacCap recording (left = you, right =
/// them) through the live transcribers and the notes model, as fast as they
/// take it, so live notes can be checked without a call.
final class NotesReplayCommand: NSObject, NSApplicationDelegate {
    let file: URL
    /// Ask the assist for help, or ask it a question, once the audio is in.
    let help: Bool
    let question: String?
    /// Then a follow-up to that answer.
    let followUp: String?

    init(file: URL, help: Bool = false, question: String? = nil, followUp: String? = nil) {
        self.file = file
        self.help = help
        self.question = question
        self.followUp = followUp
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard #available(macOS 26.0, *) else {
            print("live notes need macOS 26 or later")
            exit(2)
        }
        Task { @MainActor in
            do {
                try await self.replay()
            } catch {
                print("error: \(error)")
                exit(2)
            }
        }
    }

    @available(macOS 26.0, *)
    @MainActor
    private func replay() async throws {
        let audio = try AVAudioFile(forReading: file)
        let format = audio.processingFormat
        guard format.channelCount == 2 else { throw NotesModelError(description: "expected a stereo MacCap file") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maccap-notes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let live = LiveNotesController(config: config, originHost: 0, sessionDir: dir)
        live.onFinalLine = printLine
        live.onCard = printCard
        live.startAssist()
        guard await live.prepare() else { exit(2) }
        let rate = format.sampleRate
        let chunk = AVAudioFrameCount(rate / 10)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { exit(2) }
        var position = 0.0
        let started = Date()
        while audio.framePosition < audio.length {
            try audio.read(into: buffer, frameCount: chunk)
            let n = Int(buffer.frameLength)
            guard n > 0, let data = buffer.floatChannelData else { break }
            live.feed(.mic, Array(UnsafeBufferPointer(start: data[0], count: n)), rate: rate, startHost: position)
            live.feed(.system, Array(UnsafeBufferPointer(start: data[1], count: n)), rate: rate, startHost: position)
            position += Double(n) / rate
        }
        print("fed \(String(format: "%.1f", position)) s of audio in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        if live.assistView.running && (help || question != nil) {
            try await Task.sleep(for: .seconds(3))  // let the last lines reach the transcript
            if help { live.help() }
            if let question { live.ask(question) }
            func answered() async throws {
                let deadline = Date().addingTimeInterval(200)  // an assist may take up to 180 s
                while !live.assistView.waiting.isEmpty && live.assistView.running && Date() < deadline {
                    try await Task.sleep(for: .milliseconds(200))
                }
            }
            try await answered()
            if let followUp, let root = live.assistView.cards.last(where: { $0.kind == .answer && $0.parent == nil }) {
                live.followUp(followUp, on: root.id)
                try await answered()
            }
        }
        live.finish(timeout: 120) {
            printNotes(live.finalNotes)
            print("notes file: \(dir.appendingPathComponent(LiveNotesFiles.sessionFile).path)")
            Log.shared.flush()
            exit(0)
        }
    }
}

func runCallers() {
    let matcher = CallMatcher(allowlist: config.effectiveAllowlist, ownPID: getpid())
    let processes = AudioProcess.all().sorted { ($0.runningInput ? 0 : 1, $0.pid) < ($1.runningInput ? 0 : 1, $1.pid) }
    let output = AudioHAL.defaultDevice(input: false)
    let input = AudioHAL.defaultDevice(input: true)
    print("output: \(AudioHAL.deviceName(output) ?? "?") (\(AudioHAL.transportName(output)), "
        + "\(Int(AudioHAL.nominalRate(output))) Hz)")
    print("input:  \(AudioHAL.deviceName(input) ?? "?") (\(AudioHAL.transportName(input)), "
        + "\(Int(AudioHAL.nominalRate(input))) Hz)")
    print("")
    print("  PID  IN OUT CALL  PROCESS / BUNDLE ID")
    for process in processes where process.runningInput || process.runningOutput
        || matcher.matches(bundleID: process.bundleID, name: process.name) {
        let call = matcher.activeCallers([process]).isEmpty
            ? (matcher.matches(bundleID: process.bundleID, name: process.name) ? "  -  " : "     ")
            : " YES "
        print(String(format: "%5d  %@  %@ %@ %@ (%@)", process.pid, process.runningInput ? "●" : "·",
                     process.runningOutput ? "●" : "·", call, process.displayName, process.bundleID ?? "no bundle id"))
    }
    let active = matcher.activeCallers(processes)
    print("")
    print(active.isEmpty ? "No call detected." : "Call detected: \(active.map(\.displayName).joined(separator: ", "))")
}

switch arguments.first {
case nil:
    guard takeMenuLock() else {
        Log.shared.write("another MacCap menu app is running; exiting")
        exit(0)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = AppController(paths: paths, config: config)
    app.delegate = controller
    app.run()
case "record":
    let seconds = option("--seconds").flatMap(Double.init) ?? 20
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let command = RecordCommand(seconds: seconds, notes: arguments.contains("--notes"))
    app.delegate = command
    app.run()
case "notes":
    guard arguments.count > 1 else {
        usage()
        exit(64)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let command = NotesReplayCommand(file: URL(fileURLWithPath: arguments[1]), help: arguments.contains("--help-me"),
                                     question: option("--ask"), followUp: option("--follow-up"))
    app.delegate = command
    app.run()
case "demo":
    guard arguments.count > 1 else {
        usage()
        exit(64)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let command = DemoCommand(file: URL(fileURLWithPath: arguments[1]),
                              speed: option("--speed").flatMap(Double.init) ?? 1)
    app.delegate = command
    app.run()
case "callers":
    runCallers()
case "finalize-pending":
    let results = Finalizer.recoverPending(paths: paths, config: config)
    if results.isEmpty { print("nothing pending") }
    for (dir, result) in results {
        switch result {
        case .success(let url): print("saved \(url.path)  (from \(dir.lastPathComponent))")
        case .failure(let error): print("FAILED \(dir.lastPathComponent): \(error)")
        }
    }
    Log.shared.flush()
    exit(results.contains { if case .failure = $0.result { return true } else { return false } } ? 1 : 0)
case "selftest":
    let passed = SelfTest.run(config: config)
    Log.shared.flush()
    exit(passed ? 0 : 1)
case "version", "--version":
    print("MacCap \(Finalizer.version)")
case "help", "-h", "--help":
    usage()
default:
    usage()
    exit(64)
}
