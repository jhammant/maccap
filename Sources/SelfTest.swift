import Foundation

/// Built-in tests: pure logic, plus a synthetic end-to-end run of the stem
/// writer and finalizer (tones and clicks at known times, no microphone).
/// Uses its own temporary MacCap home, never the real one.
enum SelfTest {
    private static var failures: [String] = []
    private static var count = 0

    private static func check(_ condition: Bool, _ name: String) {
        count += 1
        if !condition {
            failures.append(name)
            print("FAIL  \(name)")
        }
    }

    static func run(config: MacCapConfig) -> Bool {
        placement()
        remoteSilence()
        autoPolicy()
        matcher()
        naming()
        liveNotes()
        assist()
        markdown()
        topics()
        coach()
        notesMerge()
        followUp()
        consent()
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("maccap-selftest-\(UUID().uuidString)", isDirectory: true)
        let paths = MacCapPaths(home: home, audio: home.appendingPathComponent("audio"),
                                sessions: home.appendingPathComponent("sessions"),
                                log: home.appendingPathComponent("maccap.log"),
                                config: home.appendingPathComponent("config.json"),
                                state: home.appendingPathComponent("state.json"))
        do {
            try paths.ensure()
            if config.resolveFFmpeg() == nil {
                print("SKIP  writer/finalizer tests: ffmpeg not found")
            } else {
                try writerAndFinalizer(paths: paths, config: config)
                try missingStem(paths: paths, config: config)
                try crashRecovery(paths: paths, config: config)
                emptySession(paths: paths, config: config)
                try setAside(paths: paths)
            }
        } catch {
            check(false, "end-to-end threw \(error)")
        }
        print("\(count - failures.count)/\(count) checks passed" + (failures.isEmpty ? "" : "; failed: \(failures)"))
        print("temporary files: \(home.path)")
        return failures.isEmpty
    }

    // MARK: Pure logic

    static func consent() {
        let old = try? JSONDecoder().decode(MacCapState.self, from: Data(#"{"autoPaused":false}"#.utf8))
        check(old?.consentAccepted == false, "consent: a state file from before consent records nothing")
        var state = MacCapState()
        state.consentAccepted = true
        let again = (try? JSONEncoder().encode(state)).flatMap { try? JSONDecoder().decode(MacCapState.self, from: $0) }
        check(again?.consentAccepted == true, "consent: agreeing is remembered")
        check(MacCapConfig().consent == MacCapConfig.defaultConsentMessage, "consent: a default message")
        let custom = try? JSONDecoder().decode(MacCapConfig.self, from: Data(#"{"consent_message":"  OK to record?  "}"#.utf8))
        check(custom?.consent == "OK to record?", "consent: consent_message replaces it")
        let blank = try? JSONDecoder().decode(MacCapConfig.self, from: Data(#"{"consent_message":" "}"#.utf8))
        check(blank?.consent == MacCapConfig.defaultConsentMessage, "consent: a blank message falls back")
    }

    static func topics() {
        let reply = """
        <think>hmm</think>
        [00:05] Introductions
        - **[02:10] Priya's volumes**
        12:40 – Pricing bands
        1:02:30 Next steps
        not a part
        """
        let parsed = TopicsPrompt.parse(reply)
        check(parsed == [CallTopic(start: 5, title: "Introductions"), CallTopic(start: 130, title: "Priya's volumes"),
                         CallTopic(start: 760, title: "Pricing bands"), CallTopic(start: 3750, title: "Next steps")],
              "parts: parsed from the model's lines (got \(parsed))")
        // First pass: the first part starts with the call, the far-future one is dropped.
        var topics = CallTopics.merged([], fresh: parsed, now: 900)
        check(topics.map(\.start) == [0, 130, 760], "parts: first pass (got \(topics))")
        // Later: the open part is restated a little off and retitled, a new part
        // is added; closed parts never move, an aside 20 s long is dropped.
        let fresh = [CallTopic(start: 770, title: "Pricing bands and floor"), CallTopic(start: 790, title: "Aside"),
                     CallTopic(start: 1200, title: "Rollout"), CallTopic(start: 100, title: "Rewritten history")]
        topics = CallTopics.merged(topics, fresh: fresh, now: 1300)
        check(topics == [CallTopic(start: 0, title: "Introductions"), CallTopic(start: 130, title: "Priya's volumes"),
                         CallTopic(start: 760, title: "Pricing bands and floor"), CallTopic(start: 1200, title: "Rollout")],
              "parts: open part refreshed, closed parts kept (got \(topics))")
        // A reply that leaves the open part out, or fails, loses nothing.
        check(CallTopics.merged(topics, fresh: [], now: 1400) == topics, "parts: an empty reply changes nothing")
        let kept = CallTopics.merged(topics, fresh: [CallTopic(start: 1300, title: "Next steps")], now: 1400)
        check(kept.map(\.title) == ["Introductions", "Priya's volumes", "Pricing bands and floor", "Rollout", "Next steps"],
              "parts: the open part is kept when the model leaves it out")
        check(CallTopics.index(at: 759, in: topics) == 1 && CallTopics.index(at: 760, in: topics) == 2,
              "parts: a line falls in the part it starts in")

        let view = LiveNotesViewModel()
        view.lines = [0, 60, 140, 200, 800].map {
            .init(id: "l\(Int($0))", speaker: "Priya", text: "line \(Int($0))", mine: false, inProgress: false, start: $0)
        }
        view.topics = Array(topics.prefix(3))
        check(view.parts.map { $0.lines.count } == [2, 2, 1], "parts: lines grouped under their part")
        view.toggle(view.parts[1])
        check(view.pickedTitle == "Priya's volumes" && view.pickedText.hasPrefix("[02:20] Priya: line 140"),
              "parts: a whole part picked by its heading")
        view.clearSelection()
        view.tap("l0", extend: false)
        view.tap("l200", extend: true)
        check(view.selected == ["l0", "l60", "l140", "l200"] && view.pickedTitle == nil,
              "parts: shift-click picks the run of lines")
        view.tap("l60", extend: false)
        check(!view.selected.contains("l60"), "parts: a click drops a picked line")
    }

    static func markdown() {
        let answer = """
        Ideas so far, drawing on your notes:

        - **Metric:** Priya's team handles about 1,200 orders a month.
          - a nested point
        2. **Structure:** a custom SKU
        ### Next
        > Sam wants it well above
        ✓ goal one
        ```
        tiered: up to 25M
        ```
        """
        let blocks = Markdown.parse(answer)
        check(blocks == [
            .text("Ideas so far, drawing on your notes:"), .gap,
            .bullet(indent: 0, marker: "•", text: "**Metric:** Priya's team handles about 1,200 orders a month."),
            .bullet(indent: 1, marker: "•", text: "a nested point"),
            .bullet(indent: 0, marker: "2.", text: "**Structure:** a custom SKU"),
            .heading(level: 3, text: "Next"), .quote("Sam wants it well above"), .text("✓ goal one"),
            .code("tiered: up to 25M"),
        ], "markdown: an answer's blocks (got \(blocks))")
        check(Markdown.parse("**Bold** start\n\n\n") == [.text("**Bold** start")],
              "markdown: a bold start is not a bullet, trailing blank lines dropped")
        let bold = Markdown.inline("**Metric:** rest")
        check(String(bold.characters) == "Metric: rest"
              && bold.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized },
              "markdown: **bold** loses its stars and is bold")
        check(String(Markdown.inline("[01:10] Them: say `x` and *y*").characters) == "[01:10] Them: say x and y",
              "markdown: a time stamp stays, inline marks go")
        let flat = String(Markdown.flat(blocks).characters)
        check(flat.hasPrefix("Ideas so far, drawing on your notes:\n\n• Metric: Priya's")
              && flat.contains("\n  • a nested point\n2. Structure:") && !flat.contains("**"),
              "markdown: closed cards read as plain lines (got \(flat.prefix(160)))")
    }

    static func placement() {
        check(StemPlacement.place(bufferStart: 1.4, bufferSeconds: 0.01, written: 0) == StemPlacement(padSeconds: 1.4),
              "placement: late start is padded in one step")
        check(StemPlacement.place(bufferStart: 10.03, bufferSeconds: 0.01, written: 10) == StemPlacement(),
              "placement: jitter under 50 ms is left alone")
        check(StemPlacement.place(bufferStart: 9.94, bufferSeconds: 0.01, written: 10)
              == StemPlacement(dropSeconds: StemPlacement.driftStep), "placement: ahead drift trimmed 2 ms at a time")
        check(StemPlacement.place(bufferStart: 9.5, bufferSeconds: 0.01, written: 10) == StemPlacement(dropSeconds: 0.01),
              "placement: a jump back never drops more than the buffer")
        check(StemPlacement.place(bufferStart: 9.94, bufferSeconds: 0.01, written: 10, align: true)
              == StemPlacement(dropSeconds: 0.01), "placement: align forces the whole correction")
        check(RecordingSession.nearestStandardRate(15_870) == 16_000, "rate: 15.87 kHz measured snaps to 16 kHz")
        check(RecordingSession.nearestStandardRate(47_700) == 48_000, "rate: 47.7 kHz measured snaps to 48 kHz")
    }

    static func remoteSilence() {
        // Refused permission: system exact zeros, user talking. Alert near 60 s.
        var refused = RemoteSilenceDetector()
        var alertAt: Double?
        for second in 0...90 {
            let speaking = second % 4 != 0
            if case .alert(let kind)? = refused.observe(now: Double(second), micLevel: speaking ? 20 : 0,
                                                        systemLevel: 0), alertAt == nil {
                alertAt = Double(second)
                check(kind == .neverHeard, "silence: refused tap is reported as never-heard")
            }
        }
        check(alertAt.map { $0 >= 60 && $0 <= 65 } ?? false, "silence: alert within about a minute (got \(alertAt ?? -1))")

        // Waiting for the call to connect, nobody talking: never alarm.
        var quiet = RemoteSilenceDetector()
        var quietAlerts = 0
        for second in 0...300 {
            if quiet.observe(now: Double(second), micLevel: 0, systemLevel: 0) != nil { quietAlerts += 1 }
        }
        check(quietAlerts == 0, "silence: a quiet room never alarms")

        // Normal call: both sides heard.
        var normal = RemoteSilenceDetector()
        var normalAlerts = 0
        for second in 0...600 {
            let them = second % 10 < 5
            if normal.observe(now: Double(second), micLevel: them ? 0 : 20, systemLevel: them ? 20 : 0) != nil {
                normalAlerts += 1
            }
        }
        check(normalAlerts == 0 && normal.remoteHeard, "silence: a normal call never alarms")

        // Heard, then lost for two minutes, then back.
        var lost = RemoteSilenceDetector()
        var events: [RemoteSilenceDetector.Event] = []
        for second in 0...20 { _ = lost.observe(now: Double(second), micLevel: 0, systemLevel: 20) }
        for second in 21...160 {
            if let event = lost.observe(now: Double(second), micLevel: 20, systemLevel: 0) { events.append(event) }
        }
        for second in 161...170 {
            if let event = lost.observe(now: Double(second), micLevel: 0, systemLevel: 20) { events.append(event) }
        }
        check(events == [.alert(.lost), .recovered], "silence: dropout alerts after two minutes, then recovers")
    }

    static func autoPolicy() {
        var policy = AutoPolicy(startAfter: 4, stopAfterQuiet: 90)
        check(policy.step(now: 0, callActive: true, recording: nil, paused: false) == .none, "auto: not at first sight")
        check(policy.step(now: 2, callActive: true, recording: nil, paused: false) == .none, "auto: not at 2 s")
        check(policy.step(now: 4, callActive: true, recording: nil, paused: false) == .start, "auto: starts at 4 s")

        var blip = AutoPolicy(startAfter: 4, stopAfterQuiet: 90)
        _ = blip.step(now: 0, callActive: true, recording: nil, paused: false)
        _ = blip.step(now: 2, callActive: false, recording: nil, paused: false)
        check(blip.step(now: 4, callActive: true, recording: nil, paused: false) == .none,
              "auto: a 2 s blip does not start a recording")

        var stop = AutoPolicy(startAfter: 4, stopAfterQuiet: 90)
        _ = stop.step(now: 0, callActive: false, recording: .auto, paused: false)
        check(stop.step(now: 88, callActive: false, recording: .auto, paused: false) == .none, "auto: still on at 88 s quiet")
        check(stop.step(now: 90, callActive: false, recording: .auto, paused: false) == .stop, "auto: stops after 90 s quiet")
        check(stop.stopsIn(now: 60) == 30 && AutoPolicy(startAfter: 4, stopAfterQuiet: 45).stopsIn(now: 0) == nil,
              "auto: countdown once the call is quiet")
        check(MacCapConfig().stopAfterQuiet == 45, "auto: stops 45 s after the call by default")

        var held = AutoPolicy(startAfter: 4, stopAfterQuiet: 45)
        _ = held.step(now: 0, callActive: true, recording: nil, paused: false)
        held.holdUntilQuiet()   // You pressed Stop; the Meet tab still has the mic
        check(held.step(now: 30, callActive: true, recording: nil, paused: false) == .none,
              "auto: a stopped call does not restart while its app keeps the mic")
        _ = held.step(now: 40, callActive: false, recording: nil, paused: false)
        _ = held.step(now: 90, callActive: false, recording: nil, paused: false)
        _ = held.step(now: 100, callActive: true, recording: nil, paused: false)
        check(held.step(now: 104, callActive: true, recording: nil, paused: false) == .start && !held.holding,
              "auto: the next call after a stop is recorded")

        var manual = AutoPolicy(startAfter: 4, stopAfterQuiet: 90)
        _ = manual.step(now: 0, callActive: false, recording: .manual, paused: false)
        check(manual.step(now: 600, callActive: false, recording: .manual, paused: false) == .none,
              "auto: manual sessions never auto-stop")

        var paused = AutoPolicy(startAfter: 4, stopAfterQuiet: 90)
        _ = paused.step(now: 0, callActive: true, recording: nil, paused: true)
        check(paused.step(now: 10, callActive: true, recording: nil, paused: true) == .none, "auto: paused never starts")

        var skip = AutoPolicy(startAfter: 4, stopAfterQuiet: 90)
        _ = skip.step(now: 0, callActive: true, recording: nil, paused: false)
        skip.skipCurrentCall()
        check(skip.step(now: 30, callActive: true, recording: nil, paused: false) == .none, "auto: skipped call stays skipped")
        _ = skip.step(now: 40, callActive: false, recording: nil, paused: false)
        _ = skip.step(now: 130, callActive: false, recording: nil, paused: false)
        _ = skip.step(now: 200, callActive: true, recording: nil, paused: false)
        check(skip.step(now: 204, callActive: true, recording: nil, paused: false) == .start,
              "auto: the next call after a skip is recorded")
    }

    static func matcher() {
        let matcher = CallMatcher(allowlist: MacCapConfig.defaultAllowlist, ownPID: 1)
        check(matcher.matches(bundleID: "com.google.Chrome.helper", name: "Google Chrome Helper"), "match: Chrome helper")
        check(matcher.matches(bundleID: "com.apple.WebKit.GPU", name: "com.apple.WebKit.GPU"), "match: Safari GPU process")
        check(matcher.matches(bundleID: nil, name: "avconferenced"), "match: FaceTime daemon by name")
        check(matcher.matches(bundleID: nil, name: "callservicesd"), "match: phone calls daemon by name")
        check(matcher.matches(bundleID: "us.zoom.xos", name: "zoom.us"), "match: Zoom")
        check(!matcher.matches(bundleID: "io.maccap.MacCap", name: "MacCap"), "match: not MacCap itself")
        check(!matcher.matches(bundleID: "com.apple.VoiceMemos", name: "VoiceMemos"), "match: not Voice Memos")
    }

    static func naming() {
        var components = DateComponents()
        components.year = 2026; components.month = 11; components.day = 4
        components.hour = 9; components.minute = 5; components.second = 7
        let date = Calendar.current.date(from: components)!
        let name = "\(Clock.fileStamp(date))-\(Clock.newSessionID()).m4a"
        let pattern = try! NSRegularExpression(pattern: "^\\d{8} \\d{6}-[0-9a-f]{8}\\.m4a$")
        check(pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil,
              "naming: \(name) matches the Voice Memos pattern")
        check(name.hasPrefix("20261104 090507-"), "naming: local time stamp")
    }

    // MARK: End to end (synthetic)

    private final class ManifestBox {
        var manifest: SessionManifest
        init(_ manifest: SessionManifest) { self.manifest = manifest }
    }

    /// Feeds 10 ms buffers of a tone with 2 ms clicks at known times.
    private static func feed(_ writer: StemWriter, rate: Double, from: Double, to: Double, origin: Double,
                             tone: Double, clicks: [Double], skip: ClosedRange<Double>? = nil,
                             clockScale: Double = 1, rotateAt: Double? = nil) {
        let frames = Int(rate * 0.01)
        var t = from
        var rotated = false
        while t < to - 1e-9 {
            if let rotateAt, !rotated, t >= rotateAt {
                writer.newSegment(reason: "selftest_rotate", route: nil)
                rotated = true
            }
            if let skip, skip.contains(t) {
                t += 0.01
                continue
            }
            var samples = [Float](repeating: 0, count: frames)
            for index in 0..<frames {
                let time = t + Double(index) / rate
                var value = 0.1 * sin(2 * Double.pi * tone * time)
                if clicks.contains(where: { time >= $0 && time < $0 + 0.002 }) { value = 0.9 }
                samples[index] = Float(value)
            }
            writer.append(samples, rate: rate, startHost: origin + t * clockScale)
            t += 0.01
        }
    }

    private static func makeSession(_ paths: MacCapPaths, id: String, state: String, pid: Int32)
        -> (URL, ManifestBox) {
        let stamp = "20261104 1200\(id.prefix(2))"
        let dir = paths.sessions.appendingPathComponent("\(stamp.replacingOccurrences(of: " ", with: "-"))-\(id)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let box = ManifestBox(SessionManifest(id: id, stamp: stamp, startedAt: Clock.iso(Date()), trigger: "selftest",
                                              state: state, pid: pid))
        return (dir, box)
    }

    /// Decodes the final file to interleaved stereo floats at 48 kHz.
    private static func decode(_ url: URL, config: MacCapConfig) -> [Float] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.resolveFFmpeg()!)
        process.arguments = ["-nostdin", "-v", "error", "-i", url.path, "-f", "f32le", "-ac", "2", "-ar", "48000", "-"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    private static func peakTime(_ stereo: [Float], channel: Int, near: Double) -> Double {
        let rate = 48_000.0
        let from = max(0, Int((near - 0.05) * rate)), to = min(stereo.count / 2, Int((near + 0.05) * rate))
        var best = 0, bestValue: Float = 0
        for frame in from..<max(from, to) where abs(stereo[frame * 2 + channel]) > bestValue {
            bestValue = abs(stereo[frame * 2 + channel])
            best = frame
        }
        return Double(best) / rate
    }

    private static func rms(_ stereo: [Float], channel: Int, from: Double, to: Double) -> Double {
        let rate = 48_000.0
        let start = Int(from * rate), end = min(stereo.count / 2, Int(to * rate))
        guard end > start else { return 0 }
        var sum = 0.0
        for frame in start..<end { sum += Double(stereo[frame * 2 + channel] * stereo[frame * 2 + channel]) }
        return (sum / Double(end - start)).squareRoot()
    }

    static func writerAndFinalizer(paths: MacCapPaths, config: MacCapConfig) throws {
        let (dir, box) = makeSession(paths, id: "a1b2c3d4", state: "recording", pid: getpid())
        let origin = 1000.0
        let mic = StemWriter(name: "mic", dir: dir, originHost: origin) { box.manifest.micSegments.append($0) }
        let system = StemWriter(name: "system", dir: dir, originHost: origin) { box.manifest.systemSegments.append($0) }
        mic.open(reason: "start", route: nil)
        system.open(reason: "start", route: nil)
        // Mic: 48 kHz from 0 s, a new segment at 1.5 s (route change).
        feed(mic, rate: 48_000, from: 0, to: 3, origin: origin, tone: 440, clicks: [1.0, 2.0, 2.8], rotateAt: 1.5)
        // System: AirPods-style 16 kHz, starts late at 0.8 s, stalls 1.4-1.7 s,
        // and its clock runs 0.3% fast (drift the timeline must absorb).
        feed(system, rate: 16_000, from: 0.8, to: 3, origin: origin, tone: 880, clicks: [1.0, 2.0, 2.8],
             skip: 1.4...1.69, clockScale: 1.003)
        _ = mic.close()
        _ = system.close()
        box.manifest.state = "stopped"
        box.manifest.micStats = mic.snapshot
        box.manifest.systemStats = system.snapshot
        box.manifest.save(dir)

        let url = try Finalizer.finalize(sessionDir: dir, paths: paths, config: config)
        let stereo = decode(url, config: config)
        let duration = Double(stereo.count / 2) / 48_000
        check(abs(duration - 3.0) < 0.06, "e2e: duration \(String(format: "%.3f", duration)) s ≈ 3.0 s")
        var report: [String] = []
        for (channel, label) in [(0, "L"), (1, "R")] {
            for click in [1.0, 2.0, 2.8] {
                let expected = label == "R" ? click * 1.003 : click
                let error = peakTime(stereo, channel: channel, near: expected) - expected
                report.append("\(label)@\(click): \(String(format: "%+.1f", error * 1000)) ms")
                // The drifting system clock is pulled back toward the timeline
                // 2 ms per buffer, so it may sit up to the 50 ms tolerance.
                check(abs(error) < (label == "R" ? 0.055 : 0.006), "e2e: \(label) click at \(click) s placed (\(error))")
            }
        }
        print("      click placement: " + report.joined(separator: ", "))
        check(rms(stereo, channel: 1, from: 0.05, to: 0.75) < 0.002, "e2e: right channel silent before system starts")
        check(rms(stereo, channel: 0, from: 0.05, to: 0.75) > 0.03, "e2e: left channel carries the mic tone")
        check(rms(stereo, channel: 1, from: 1.45, to: 1.65) < 0.002, "e2e: system stall is silence, not shifted audio")
        let sidecar = url.deletingPathExtension().appendingPathExtension("maccap.json")
        let json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: sidecar))) as? [String: Any]
        check((json?["channels"] as? [String: Any]) != nil, "e2e: sidecar written with channels")
        check(((json?["health"] as? [String: Any])?["verdict"] as? String) == "both_sides", "e2e: health both sides")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        check((attributes[.posixPermissions] as? Int) == 0o600, "e2e: final file is owner-only (0600)")
        check(!url.lastPathComponent.hasPrefix("."), "e2e: final file is visible")
        let leftovers = (try FileManager.default.contentsOfDirectory(atPath: paths.audio.path)).filter { $0.hasSuffix(".part") }
        check(leftovers.isEmpty, "e2e: no temp file left behind")
        check(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic-002.aac").path),
              "e2e: raw segments kept")
    }

    static func missingStem(paths: MacCapPaths, config: MacCapConfig) throws {
        let (dir, box) = makeSession(paths, id: "b2c3d4e5", state: "stopped", pid: getpid())
        let mic = StemWriter(name: "mic", dir: dir, originHost: 0) { box.manifest.micSegments.append($0) }
        mic.open(reason: "start", route: nil)
        feed(mic, rate: 44_100, from: 0, to: 2, origin: 0, tone: 440, clicks: [])
        _ = mic.close()
        box.manifest.save(dir)
        let url = try Finalizer.finalize(sessionDir: dir, paths: paths, config: config)
        let stereo = decode(url, config: config)
        check(stereo.count / 2 > 90_000, "missing stem: still stereo with full length")
        check(rms(stereo, channel: 1, from: 0.1, to: 1.9) == 0, "missing stem: right channel is silence")
    }

    static func crashRecovery(paths: MacCapPaths, config: MacCapConfig) throws {
        // A session still marked "recording" by a process that no longer exists.
        let (dir, box) = makeSession(paths, id: "c3d4e5f6", state: "recording", pid: 999_999)
        let mic = StemWriter(name: "mic", dir: dir, originHost: 0) { box.manifest.micSegments.append($0) }
        let system = StemWriter(name: "system", dir: dir, originHost: 0) { box.manifest.systemSegments.append($0) }
        mic.open(reason: "start", route: nil)
        system.open(reason: "start", route: nil)
        feed(mic, rate: 48_000, from: 0, to: 1.5, origin: 0, tone: 440, clicks: [])
        feed(system, rate: 48_000, from: 0, to: 1.5, origin: 0, tone: 660, clicks: [])
        _ = mic.close()
        _ = system.close()
        box.manifest.save(dir)
        // Truncate the system segment mid-frame, as a kill -9 would.
        let systemFile = dir.appendingPathComponent("system-001.aac")
        let handle = try FileHandle(forWritingTo: systemFile)
        let size = try handle.seekToEnd()
        try handle.truncate(atOffset: size - 37)
        try handle.close()

        check(Finalizer.pending(paths: paths).contains { $0.lastPathComponent == dir.lastPathComponent },
              "recovery: dead session is pending")
        let results = Finalizer.recoverPending(paths: paths, config: config)
        let recovered = results.first { $0.dir.lastPathComponent == dir.lastPathComponent }
        if case .success(let url)? = recovered?.result {
            let sidecar = url.deletingPathExtension().appendingPathExtension("maccap.json")
            let json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: sidecar))) as? [String: Any]
            check(json?["recovered_after_crash"] as? Bool == true, "recovery: sidecar marks the crash")
            let stereo = decode(url, config: config)
            check(rms(stereo, channel: 1, from: 0.1, to: 1.3) > 0.03, "recovery: truncated stem still decodes")
        } else {
            check(false, "recovery: finalized (\(String(describing: recovered?.result)))")
        }
        check(Finalizer.pending(paths: paths).isEmpty, "recovery: nothing left pending")
    }

    static func emptySession(paths: MacCapPaths, config: MacCapConfig) {
        // Capture never got going (no permission, a dead tap): nothing to save.
        let (dir, box) = makeSession(paths, id: "d4e5f6a7", state: "stopped", pid: getpid())
        box.manifest.save(dir)
        var noAudio = false
        do { _ = try Finalizer.finalize(sessionDir: dir, paths: paths, config: config) } catch let error as FinalizeError {
            noAudio = error.noAudio
        } catch {}
        check(noAudio, "empty session: reported as no audio")
        check((try? SessionManifest.load(dir))?.state == "empty", "empty session: marked empty")
        check(!Finalizer.pending(paths: paths).contains { $0.lastPathComponent == dir.lastPathComponent },
              "empty session: not retried")
        check(FileManager.default.fileExists(atPath: dir.path), "empty session: folder kept")
    }

    // MARK: Call assist

    private static func assist() {
        func decode(_ json: String) -> AssistMessage? { AssistMessage.decode(Data(json.utf8)) }
        if case .card(let card)? = decode(#"{"type":"card","id":"p1","kind":"hologram","title":"Dana","at":62}"#) {
            check(card.kind == .note && card.title == "Dana" && card.at == 62, "assist: unknown kind shows as a note")
        } else {
            check(false, "assist: card decodes")
        }
        check(decode(#"{"type":"card","id":"p1"}"#) == nil, "assist: card without a title is skipped")
        check(decode("not json") == nil && decode(#"{"type":"teleport"}"#) == nil, "assist: unknown lines skipped")
        if case .speaker(let stem, let start, let end, let name)? =
            decode(#"{"type":"speaker","stem":"system","start":10,"end":14.5,"name":"Dana"}"#) {
            check(stem == .system && start == 10 && end == 14.5 && name == "Dana", "assist: speaker decodes")
        } else {
            check(false, "assist: speaker decodes")
        }

        if case .choices(let options, let selected)? = decode(#"{"type":"choices","options":[{"id":"a.json","label":"14:00 Sokin"},{"id":"b"}],"selected":"a.json"}"#) {
            check(options == [AssistChoice(id: "a.json", label: "14:00 Sokin")] && selected == "a.json",
                  "assist: meeting choices decode, half-made ones skipped")
        } else {
            check(false, "assist: meeting choices decode")
        }

        // Live speaker names: lines already there are named, later ones too.
        var t = LiveTranscript()
        t.add(LiveLine(stem: .system, start: 10, end: 14, text: "We moved the launch to March."))
        t.add(LiveLine(stem: .mic, start: 15, end: 17, text: "Why March?"))
        t.nameSpeaker(.init(stem: .system, start: 9.5, end: 14.2, name: "Dana"))
        t.nameSpeaker(.init(stem: .system, start: 18, end: 25, name: "Sam"))
        t.add(LiveLine(stem: .system, start: 18.5, end: 22, text: "The audit log slipped."))
        t.add(LiveLine(stem: .system, start: 30, end: 36, text: "Anything else?"))   // nobody named yet
        t.nameSpeaker(.init(stem: .system, start: 35, end: 36, name: "Dana"))         // covers a sixth: not enough
        check(t.lines.map(\.label) == ["Dana", "You", "Sam", "Them"], "assist: live speaker names")
        check(t.text().contains("Dana: We moved the launch"), "assist: names reach the transcript")

        // Cards: pinned first, newest first; an answered request is outlined.
        let model = AssistViewModel()
        model.upsert(AssistCard(id: "a", kind: .person, title: "A"))
        model.upsert(AssistCard(id: "help-1", kind: .answer, title: "Help", quote: "When?", at: 205, state: .looking,
                                pinned: true))
        model.waiting.insert("help-1")
        model.upsert(AssistCard(id: "b", kind: .company, title: "B"))
        check(model.ordered.map(\.id) == ["help-1", "b", "a"], "assist: pinned first, then newest")
        model.upsert(AssistCard(id: "help-1", kind: .answer, title: "Help", body: "Say Q1", state: .ready, pinned: true))
        check(model.waiting.isEmpty && model.highlighted == "help-1" && model.cards.count == 3,
              "assist: an answer replaces its placeholder and is outlined")
        let answer = model.cards.first { $0.id == "help-1" }
        check(answer?.at == 205 && answer?.quote == "When?" && answer?.body == "Say Q1",
              "assist: an answer keeps its placeholder's time and words")


        // Follow-ups: inside their answer's card, carrying the thread so far.
        model.upsert(AssistCard(id: "ask-2", kind: .answer, title: "And the date?", at: 260, state: .looking,
                                pinned: true, parent: "help-1"))
        model.waiting.insert("ask-2")
        check(model.ordered.map(\.id) == ["help-1", "b", "a"] && model.thread("help-1").map(\.id) == ["ask-2"],
              "assist: a follow-up is shown inside its answer, not on its own")
        check(model.conversation("help-1") == [["question": "Help (about “When?”)", "answer": "Say Q1"]],
              "assist: a follow-up carries the answers so far, not the one still looking")
        model.upsert(AssistCard(id: "ask-2", kind: .answer, title: "And the date?", body: "End of Q1.", state: .ready,
                                pinned: true))
        check(model.highlighted == "help-1" && model.thread("help-1").first?.body == "End of Q1.",
              "assist: an answered follow-up stays in its thread and outlines it")
        check(model.conversation("help-1").map { $0["question"] ?? "" } == ["Help (about “When?”)", "And the date?"],
              "assist: the thread grows, oldest first")
        model.remove("help-1")
        check(model.cards.map(\.id) == ["a", "b"], "assist: removing an answer removes its follow-ups")
    }

    // MARK: Notes that only grow

    private static func notesMerge() {
        let first = LiveNotesSections(keyPoints: ["Beta shipped to 3 customers"],
                                      questions: ["(Them) When is EU hosting ready?"],
                                      actions: ["(You) Send the pricing note by Friday", "(Them) Fix the connector"])
        // The next update forgets one action, rewords another and adds one.
        let second = LiveNotesSections(keyPoints: ["Beta shipped to three customers", "Demo on Friday"],
                                       questions: [],
                                       actions: ["(You) Send the pricing note by Monday", "(Them) Book the demo"])
        let merged = first.merged(with: second)
        check(merged.actions == ["(You) Send the pricing note by Monday", "(Them) Fix the connector",
                                 "(Them) Book the demo"], "notes: actions are kept, updated and added")
        check(merged.questions == ["(Them) When is EU hosting ready?"], "notes: a question is not forgotten")
        check(merged.keyPoints == ["Beta shipped to three customers", "Demo on Friday"],
              "notes: a reworded point replaces the old one")
        let two = LiveNotesSections(actions: ["(Them) Fix the connector by Thursday"])
            .merged(with: LiveNotesSections(actions: ["(Them) Fix the login by Thursday"]))
        check(two.actions.count == 2, "notes: two different actions with the same date both stay")
        let many = LiveNotesSections(keyPoints: (1...20).map { "Point number \($0) about topic \($0 * 7)" })
        check(LiveNotesSections().merged(with: many).keyPoints.count == LiveNotesSections.maxKeyPoints,
              "notes: key points keep the newest")
    }

    // MARK: Meeting finished

    private static func followUp() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("maccap-followup-\(UUID().uuidString).json")
        let actions = ["(You) Send the deck", "(Them) Send volumes", "(You) a", "(You) b", "(You) c", "(You) d"]
        let summary = MeetingSummary(title: "Test call", startedAt: Date(timeIntervalSince1970: 0), duration: 600,
                                     apps: ["Zoom"], notes: LiveNotesSections(actions: actions),
                                     talk: TalkStats(), recording: URL(fileURLWithPath: "/tmp/a.m4a"))
        let model = FinishedViewModel(summary: summary, canHandOff: true)
        check(model.steps.map(\.text) == ["(You) Send the deck", "(You) a", "(You) b", "(You) c"],
              "finished: without a rewrite, only your own live actions, four at most, no stock lines")
        for i in 1..<model.steps.count { model.steps[i].selected = false }
        func run(_ script: String) -> FinishedViewModel.Handoff? {
            var result: FinishedViewModel.Handoff?
            FollowUp.run(command: ["/bin/sh", "-c", script, file.path], payload: summary.payload(steps: model.chosen),
                         timeout: 20) { result = $0 }
            let deadline = Date().addingTimeInterval(20)
            while result == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            return result
        }
        let ok = run(#"cat > "$0"; echo noise >&2; echo '{"status":"Handed over","url":"https://example.com/x"}'"#)
        check(ok == .done("Handed over", URL(string: "https://example.com/x")), "finished: hand-off reads the reply")
        let sent = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any]
        check(sent?["type"] as? String == "meeting_finished"
              && sent?["next_steps"] as? [String] == ["You: (You) Send the deck"],
              "finished: only the ticked steps are sent, labelled with whose they are")
        if case .failed? = run("cat > /dev/null; exit 3") {} else { check(false, "finished: a failing command shows as failed") }

        // With a rewrite coming: your own steps only, then Claude's few.
        var withAdded = summary
        withAdded.expectRewrite = true
        withAdded.addedSteps = [("You to send the deck", true)]
        let refined = FinishedViewModel(summary: withAdded, canHandOff: true)
        check(refined.steps.map(\.text) == ["You to send the deck"], "finished: no live-note noise while Claude works")
        refined.refine(ai: ["Draft the email to Dana with the deck.", "Research Dana's team."], mine: ["Call Sam."],
                       waiting: ["Dana will send volumes."], keyPoints: ["k"], questions: [], by: "test")
        check(refined.steps.map(\.text) == ["You to send the deck", "Draft the email to Dana with the deck.",
                                             "Research Dana's team.", "Call Sam."]
              && refined.steps.map(\.owner) == [.you, .claude, .claude, .you]
              && refined.waitingOn == ["Dana will send volumes."] && refined.keyPoints == ["k"],
              "finished: Claude's steps and yours, other people's promises apart")
        check(refined.chosen.first == "You: You to send the deck" && refined.chosen[1].hasPrefix("Claude: Draft"),
              "finished: the hand-off says who each step is for")
        let edited = FinishedViewModel(summary: withAdded, canHandOff: true)
        edited.steps[0].text = "Send the deck to Alex"
        edited.refine(ai: ["Draft the recap."], mine: [], keyPoints: nil, questions: nil, by: "test")
        check(edited.steps.first?.text == "Send the deck to Alex" && edited.steps.last?.selected == false,
              "finished: after you edit, rewritten steps are only added, unticked")
        check(FallbackNotesModel.lastWords("a b\nc d e\nf g", 5) == "c d e\nf g" && FallbackNotesModel.lastWords("a b\nc d e\nf g", 4) == "f g", "notes: fallback gets the newest words")
        check(MacCapConfig().phrases.contains("action point"), "moments: phrases on by default")
        try? FileManager.default.removeItem(at: file)
    }

    // MARK: Set aside

    static func setAside(paths: MacCapPaths) throws {
        let base = paths.audio.appendingPathComponent("20261105 130425-ea4025a4")
        let audio = base.appendingPathExtension("m4a")
        try Data([1, 2, 3]).write(to: audio)
        try #"{"skipped": false}"#.data(using: .utf8)!.write(to: base.appendingPathExtension("maccap.json"))
        try "notes".data(using: .utf8)!.write(to: base.appendingPathExtension("notes.md"))
        let moved = try Finalizer.setAside(audio, reason: "nobody else spoke", paths: paths)
        let folder = paths.audio.appendingPathComponent("skipped")
        check(moved == folder.appendingPathComponent(audio.lastPathComponent)
              && !FileManager.default.fileExists(atPath: audio.path), "set aside: the recording moves to skipped/")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        check(Set(names).isSuperset(of: ["20261105 130425-ea4025a4.m4a", "20261105 130425-ea4025a4.maccap.json",
                                          "20261105 130425-ea4025a4.notes.md"]), "set aside: sidecar and notes go too")
        let json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(
            "20261105 130425-ea4025a4.maccap.json")))) as? [String: Any]
        check(json?["skipped"] as? Bool == true && json?["set_aside"] as? String == "nobody else spoke",
              "set aside: the sidecar says why")
    }

    // MARK: Coach

    private static func coach() {
        let lines = [
            LiveLine(stem: .mic, start: 0, end: 20, text: "Morning. Shall we start with the plan?"),
            LiveLine(stem: .system, start: 21, end: 24, text: "Yes, go on."),          // a reply: your turn goes on
            LiveLine(stem: .mic, start: 25, end: 60, text: "So the plan is to ship the beta first and then the rest."),
            LiveLine(stem: .system, start: 61, end: 90, text: "That works for us, but we need the audit log first.",
                     name: "Dana"),
            LiveLine(stem: .mic, start: 91, end: 95, text: "What do you think?"),
        ]
        let stats = TalkStats.compute(lines)
        check(stats.people.map(\.name) == ["You", "Dana", "Them"], "coach: you first, then by talk time")
        // The 35 s line counts as 30 (maxLineSeconds): you 54 s of 86.
        check(abs(stats.yourShare - 54.0 / 86) < 0.001, "coach: your share of the talking")
        check(stats.yourQuestions == 2 && stats.theirQuestions == 0, "coach: questions counted")
        check(stats.longestRun == 60 && stats.yourRun == 4, "coach: a short reply doesn't end your turn")
        check(stats.yourRecentShare != nil && stats.elapsed == 95, "coach: recent share once there is a minute")
        check(TalkStats.compute([]).isEmpty, "coach: nothing said, nothing shown")

        var coach = Coach()
        var talking = TalkStats()
        talking.people = [.init(name: "You", seconds: 100, share: 1, mine: true)]
        talking.elapsed = 100
        talking.yourRun = 95
        let first = coach.check(talking)
        check(first?.kind == .coach && first?.title.contains("1:35") == true, "coach: nudges a long stretch")
        talking.elapsed = 150
        check(coach.check(talking) == nil, "coach: never two nudges within two minutes")
        talking.elapsed = 260
        talking.yourRun = 10
        talking.yourRecentShare = 0.8
        check(coach.check(talking)?.title.contains("80%") == true, "coach: nudges a lopsided five minutes")
        talking.elapsed = 390
        talking.yourRun = 120
        check(coach.check(talking) == nil, "coach: the same nudge waits five minutes")
        var fresh = Coach()
        var both = TalkStats()
        both.elapsed = 100
        both.yourRun = 120
        both.yourRecentShare = 0.8
        _ = fresh.check(both)  // the long stretch first
        both.elapsed = 250     // still talking: that nudge is on hold, the share one is not
        check(fresh.check(both)?.title.contains("80%") == true, "coach: a nudge on hold lets the next one through")
    }

    // MARK: Live notes

    private static func liveNotes() {
        func line(_ stem: LiveStem, _ at: Double, _ text: String) -> LiveLine {
            LiveLine(stem: stem, start: at, end: at + 2, text: text)
        }
        // Echo: the mic hears the call side through a speakerphone.
        var t = LiveTranscript()
        t.add(line(.mic, 0, "Morning both, shall we start?"))
        t.add(line(.system, 6.1, "We shipped the beta to three customers yesterday."))
        t.add(line(.mic, 6.2, "We shipped the beta to 3 customers yesterday."))   // echo after its source
        t.add(line(.mic, 14.9, "Only one, the connector timed out twice."))        // echo before its source
        t.add(line(.mic, 14.2, "Only one."))                                         // a fragment of it
        t.add(line(.system, 15.0, "Only one. The connector timed out twice."))
        t.add(line(.mic, 15.5, "Right, okay."))                                     // you over them: kept
        t.add(line(.mic, 30, "We shipped the beta to three customers yesterday.")) // you repeating later: kept
        check(t.lines.map(\.stem) == [.mic, .system, .system, .mic, .mic], "live: echo dropped both ways")
        check(t.echoDropped == 3, "live: echo count")
        check(t.text().hasPrefix("[00:00] You: Morning both"), "live: transcript text")
        check(t.text(maxWords: 6).components(separatedBy: "\n").count == 1, "live: transcript window keeps newest")
        t.volatile[.mic] = line(.mic, 15.1, "only one the connector")
        check(t.shownVolatile(.mic) == nil, "live: echoed line in progress hidden")
        t.volatile[.mic] = line(.mic, 40, "let's book Thursday")
        check(t.shownVolatile(.mic) != nil, "live: own line in progress shown")

        let reply = """
            **KEY POINTS**
            - Beta shipped to 3 customers
            QUESTIONS:
            - (You) Any problems with connectors?
            ACTIONS
            - none
            """
        let notes = LiveNotesSections.parse(reply)
        check(notes.keyPoints == ["Beta shipped to 3 customers"], "live: parse key points")
        check(notes.questions == ["(You) Any problems with connectors?"], "live: parse questions")
        check(notes.actions.isEmpty, "live: 'none' is empty")
        check(LiveNotesSections.parse("Just some text").keyPoints == ["Just some text"], "live: unformatted reply kept")
        check(LiveNotesPrompt.stripThinking("<think>hmm</think>\nKEY POINTS") == "\nKEY POINTS", "live: strip thinking")
        check(LiveNotesPrompt.request(previous: notes, transcript: "x").contains("Notes so far"), "live: rolling request")
    }
}
