import CoreAudio
import Foundation

struct AppSeen: Codable, Equatable {
    var bundleID: String?
    var name: String

    enum CodingKeys: String, CodingKey {
        case name
        case bundleID = "bundle_id"
    }
}

struct RouteEvent: Codable {
    var at: Double
    var stem: String
    var route: String
}

struct AlertEvent: Codable {
    var at: Double
    var kind: String
}

/// Written next to the raw segments as `session.json`, and rewritten as the
/// session goes on, so a crash leaves enough to finalize from.
struct SessionManifest: Codable {
    var version = 1
    var id: String
    var stamp: String
    var startedAt: String
    var endedAt: String?
    var trigger: String
    var state: String
    var pid: Int32
    var skipped = false
    var apps: [AppSeen] = []
    var micSegments: [SegmentRecord] = []
    var systemSegments: [SegmentRecord] = []
    var micStats: StemStats?
    var systemStats: StemStats?
    var routes: [RouteEvent] = []
    var alerts: [AlertEvent] = []
    var tapRebuilds = 0
    var tapMode = "global"
    var micPermission: String?
    var notes: [String] = []
    var finalFile: String?
    var finalizeError: String?
    var recovered = false

    enum CodingKeys: String, CodingKey {
        case version, id, stamp, trigger, state, pid, skipped, apps, routes, alerts, notes, recovered
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case micSegments = "mic_segments"
        case systemSegments = "system_segments"
        case micStats = "mic_stats"
        case systemStats = "system_stats"
        case tapRebuilds = "tap_rebuilds"
        case tapMode = "tap_mode"
        case micPermission = "mic_permission"
        case finalFile = "final_file"
        case finalizeError = "finalize_error"
    }

    static let fileName = "session.json"

    static func load(_ dir: URL) throws -> SessionManifest {
        try JSONDecoder().decode(SessionManifest.self,
                                 from: Data(contentsOf: dir.appendingPathComponent(fileName)))
    }

    func save(_ dir: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(self).write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
        } catch {
            Log.shared.write("session \(id): cannot write manifest: \(error)")
        }
    }
}

/// One recording: mic on the left, system audio on the right, both on one
/// host-time timeline that starts when the session does.
final class RecordingSession {
    let id: String
    let startDate: Date
    let trigger: String
    let dir: URL
    let originHost: Double
    var onAlert: ((_ title: String, _ body: String) -> Void)?
    var onRecovered: (() -> Void)?
    /// A copy of each side's samples for live notes, called on the capture
    /// threads after the samples are written. Set it before `start`.
    var liveFeed: ((_ stem: LiveStem, _ samples: [Float], _ rate: Double, _ startHost: Double) -> Void)?

    private let config: MacCapConfig
    private let control = DispatchQueue(label: "maccap.session.control")
    private let manifestLock = NSLock()
    private var manifest: SessionManifest
    private var mic: StemWriter!
    private var system: StemWriter!
    private var tap: SystemTap?
    private var micCapture: MicCapture?
    private var detector = RemoteSilenceDetector()
    private var timer: DispatchSourceTimer?
    private var ticks = 0
    /// The tap lives on its own queue: its first start blocks for as long as
    /// the System Audio Recording prompt is up (macOS gives up after 3
    /// minutes), and the mic, the health tick and stop must not wait on it.
    private let tapQueue = DispatchQueue(label: "maccap.session.tap")
    private let flagLock = NSLock()
    private var tapStartedAt = 0.0
    private var tapRunning = false
    private var tapBusy = false
    private var stopped = false
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var callBundleIDs: [String] = []

    // Measured-rate check, touched from the tap's IO queue.
    private let rateLock = NSLock()
    private var rateWindowStart: Double?
    private var rateWindowFrames = 0
    private var lastTapBufferStart: Double?
    private var rateOverride: Double?

    static let maxTapRebuilds = 8
    static let rateWindowSeconds = 10.0
    static let rateTolerance = 0.15
    static let stallSeconds = 3.0

    init(paths: MacCapPaths, config: MacCapConfig, trigger: String, apps: [AudioProcess]) throws {
        id = Clock.newSessionID()
        startDate = Date()
        self.trigger = trigger
        self.config = config
        let stamp = Clock.fileStamp(startDate)
        dir = paths.sessions.appendingPathComponent("\(stamp.replacingOccurrences(of: " ", with: "-"))-\(id)",
                                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        originHost = hostSeconds()
        manifest = SessionManifest(id: id, stamp: stamp, startedAt: Clock.iso(startDate), trigger: trigger,
                                   state: "recording", pid: getpid())
        callBundleIDs = Array(Set(apps.compactMap(\.bundleID))).sorted()
        noteApps(apps)
        manifest.save(dir)
        mic = StemWriter(name: "mic", dir: dir, originHost: originHost) { [weak self] segment in
            self?.updateManifest { $0.micSegments.append(segment) }
        }
        system = StemWriter(name: "system", dir: dir, originHost: originHost) { [weak self] segment in
            self?.updateManifest { $0.systemSegments.append(segment) }
        }
    }

    var elapsed: Double { hostSeconds() - originHost }
    private var isStopped: Bool { flagLock.withLock { stopped } }
    var isAlerting: Bool { control.sync { detector.isAlerting } }

    func start(_ ready: @escaping () -> Void) {
        control.async { [self] in
            Log.shared.write("session \(id): start (\(trigger)) in \(dir.lastPathComponent)")
            mic.open(reason: "start", route: nil)
            system.open(reason: "start", route: outputRoute())
            scheduleTap { self.startTap(reason: "start") }
            watchOutputDevice()
            startTimer()
            MicPermission.request { granted in
                self.control.async {
                    self.updateManifest { $0.micPermission = granted ? "authorized" : "denied" }
                    if granted { self.startMic() } else {
                        Log.shared.write("session \(self.id): microphone access denied; recording system audio only")
                        self.updateManifest { $0.notes.append("microphone access denied") }
                    }
                    ready()
                }
            }
        }
    }

    func noteApps(_ apps: [AudioProcess]) {
        updateManifest { manifest in
            for app in apps {
                let seen = AppSeen(bundleID: app.bundleID, name: app.displayName)
                if !manifest.apps.contains(seen) { manifest.apps.append(seen) }
            }
        }
    }

    /// Stops capture and closes the stems. Returns the session folder, ready
    /// for the finalizer.
    @discardableResult
    func stop(skipped: Bool) -> URL {
        control.sync {
            let already = flagLock.withLock { () -> Bool in
                defer { stopped = true }
                return stopped
            }
            guard !already else { return }
            timer?.cancel()
            timer = nil
            unwatchOutputDevice()
            micCapture?.stop()
            micCapture = nil
            let micSeconds = mic.close()
            let systemSeconds = system.close()
            updateManifest {
                $0.state = "stopped"
                $0.endedAt = Clock.iso(Date())
                $0.skipped = skipped
                $0.micStats = mic.snapshot
                $0.systemStats = system.snapshot
            }
            Log.shared.write("session \(id): stopped after \(String(format: "%.1f", elapsed)) s "
                + "(mic \(String(format: "%.1f", micSeconds)) s, system \(String(format: "%.1f", systemSeconds)) s)"
                + (skipped ? ", skipped by user" : ""))
        }
        // The writers are closed, so a tap still starting is harmless: it
        // is torn down as soon as its start returns.
        tapQueue.async {
            self.tap?.stop()
            self.tap = nil
        }
        return dir
    }

    /// Runs tap work on the tap queue, at most one start or rebuild queued.
    private func scheduleTap(_ work: @escaping () -> Void) {
        let queued = flagLock.withLock { () -> Bool in
            if tapBusy { return false }
            tapBusy = true
            return true
        }
        guard queued else { return }
        tapQueue.async {
            work()
            self.flagLock.withLock { self.tapBusy = false }
        }
    }

    // MARK: System audio

    private func startTap(reason: String) {
        guard !isStopped else { return }
        let narrow = (config.narrowTapToCallApps ?? false) ? callBundleIDs : []
        let tap = SystemTap(narrowToBundleIDs: narrow) { [weak self] samples, rate, start in
            guard let self else { return }
            let used = self.checkRate(frames: samples.count, reported: rate, start: start)
            self.system.append(samples, rate: used, startHost: start)
            self.liveFeed?(.system, samples, used, start)
        }
        do {
            try tap.start()
            if isStopped {
                tap.stop()
                return
            }
            self.tap = tap
            flagLock.withLock {
                tapStartedAt = hostSeconds()
                tapRunning = true
            }
            rateLock.withLock {
                rateWindowStart = nil
                rateWindowFrames = 0
                lastTapBufferStart = nil
            }
            updateManifest { $0.tapMode = tap.narrowed ? "narrowed:\(narrow.joined(separator: ","))" : "global" }
            Log.shared.write("session \(id): system tap running at \(Int(tap.currentSampleRate)) Hz "
                + "(\(tap.format.mChannelsPerFrame) ch, \(tap.narrowed ? "call apps only" : "global"), \(reason))")
        } catch {
            Log.shared.write("session \(id): system tap failed: \(error)")
            updateManifest { $0.notes.append("system tap failed (\(reason)): \(error)") }
        }
    }

    private func rebuildTap(reason: String) {
        guard !isStopped else { return }
        let rebuilds = manifestLock.withLock { manifest.tapRebuilds }
        guard rebuilds < Self.maxTapRebuilds else {
            Log.shared.write("session \(id): not rebuilding tap (\(reason)); limit reached")
            return
        }
        Log.shared.write("session \(id): rebuilding system tap (\(reason))")
        tap?.stop()
        tap = nil
        flagLock.withLock { tapRunning = false }
        updateManifest { $0.tapRebuilds += 1 }
        system.newSegment(reason: reason, route: outputRoute())
        startTap(reason: reason)
    }

    /// The AirPods trap: a Bluetooth headset in HFP runs the IOProc at 16 kHz
    /// while a stale rate says 48 kHz, which writes the stem 3x fast. Count
    /// frames against host time; when the real rate is more than 15% off the
    /// reported one, use the nearest standard rate and rebuild the tap.
    private func checkRate(frames: Int, reported: Double, start: Double) -> Double {
        var rebuildReason: String?
        let used: Double = rateLock.withLock {
            if let last = lastTapBufferStart, start - last > 1.0 {
                rateWindowStart = nil  // a stall is not a rate
            }
            lastTapBufferStart = start
            if rateWindowStart == nil {
                rateWindowStart = start
                rateWindowFrames = 0
            }
            let span = start - rateWindowStart!
            if span >= Self.rateWindowSeconds {
                let measured = Double(rateWindowFrames) / span
                let current = rateOverride ?? reported
                if abs(measured - current) / current > Self.rateTolerance {
                    let nearest = Self.nearestStandardRate(measured)
                    rebuildReason = "rate_mismatch: measured \(Int(measured)) Hz, using \(Int(current)) Hz"
                    rateOverride = nearest
                } else if rateOverride != nil, abs(measured - reported) / reported <= Self.rateTolerance {
                    rateOverride = nil
                }
                rateWindowStart = start
                rateWindowFrames = 0
            }
            rateWindowFrames += frames
            return rateOverride ?? reported
        }
        if let rebuildReason {
            Log.shared.write("session \(id): \(rebuildReason)")
            scheduleTap { self.rebuildTap(reason: rebuildReason) }
        }
        return used
    }

    static func nearestStandardRate(_ measured: Double) -> Double {
        let rates: [Double] = [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 88_200, 96_000]
        return rates.min { abs($0 - measured) < abs($1 - measured) } ?? measured
    }

    private func outputRoute() -> String {
        let device = AudioHAL.defaultDevice(input: false)
        return "\(AudioHAL.deviceName(device) ?? "unknown output") (\(AudioHAL.transportName(device)), "
            + "\(Int(AudioHAL.nominalRate(device))) Hz)"
    }

    private func watchOutputDevice() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let route = self.outputRoute()
            Log.shared.write("session \(self.id): output device now \(route)")
            self.updateManifest { $0.routes.append(RouteEvent(at: self.elapsed, stem: "system", route: route)) }
        }
        var address = globalAddress(kAudioHardwarePropertyDefaultOutputDevice)
        if AudioObjectAddPropertyListenerBlock(AudioHAL.system, &address, control, listener) == noErr {
            outputListener = listener
        }
        updateManifest { $0.routes.append(RouteEvent(at: 0, stem: "system", route: outputRoute())) }
    }

    private func unwatchOutputDevice() {
        guard let outputListener else { return }
        var address = globalAddress(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioHAL.system, &address, control, outputListener)
        self.outputListener = nil
    }

    // MARK: Microphone

    private func startMic() {
        guard !isStopped else { return }
        let capture = MicCapture(onSamples: { [weak self] samples, rate, start in
            self?.mic.append(samples, rate: rate, startHost: start)
            self?.liveFeed?(.mic, samples, rate, start)
        }, onRouteChange: { [weak self] route in
            guard let self else { return }
            self.mic.newSegment(reason: "mic_route_change", route: route)
            self.updateManifest { $0.routes.append(RouteEvent(at: self.elapsed, stem: "mic", route: route)) }
        })
        do {
            try capture.start()
            micCapture = capture
            updateManifest { $0.routes.append(RouteEvent(at: self.elapsed, stem: "mic", route: capture.route)) }
        } catch {
            Log.shared.write("session \(id): microphone failed: \(error.localizedDescription)")
            updateManifest { $0.notes.append("microphone failed: \(error.localizedDescription)") }
        }
    }

    // MARK: Health tick

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: control)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        guard !isStopped else { return }
        ticks += 1
        let now = hostSeconds()
        let micLevel = mic.takeTickPeak()
        let systemLevel = system.takeTickPeak()
        if let event = detector.observe(now: now, micLevel: micLevel, systemLevel: systemLevel) {
            switch event {
            case .alert(let kind):
                let heard = system.snapshot.heardAudio
                let message = RemoteSilenceDetector.message(kind, heardAudio: heard)
                Log.shared.write("session \(id): ALERT \(kind.rawValue): \(message.body)")
                updateManifest { $0.alerts.append(AlertEvent(at: self.elapsed, kind: kind.rawValue)) }
                onAlert?(message.title, message.body)
            case .recovered:
                Log.shared.write("session \(id): hearing the other side again")
                updateManifest { $0.alerts.append(AlertEvent(at: self.elapsed, kind: "recovered")) }
                onRecovered?()
            }
        }
        // A tap that stops calling back (device change, HAL hiccup) is
        // rebuilt; one that failed to start is retried every 10 s.
        let (running, busy, startedAt) = flagLock.withLock { (tapRunning, tapBusy, tapStartedAt) }
        if !busy {
            if running {
                let last = system.lastBufferAt ?? startedAt
                if now - max(last, startedAt) > Self.stallSeconds {
                    scheduleTap { self.rebuildTap(reason: "stalled") }
                }
            } else if ticks % 10 == 0 {
                scheduleTap { self.rebuildTap(reason: "retry_after_failure") }
            }
        }
        if ticks % 15 == 0 {
            updateManifest {
                $0.micStats = mic.snapshot
                $0.systemStats = system.snapshot
            }
        }
    }

    private func updateManifest(_ change: (inout SessionManifest) -> Void) {
        manifestLock.withLock {
            change(&manifest)
            manifest.save(dir)
        }
    }
}
