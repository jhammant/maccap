import AppKit
import ServiceManagement
import UserNotifications

/// The menu-bar app: watches for calls, records them, finalizes them.
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private let paths: MacCapPaths
    private let config: MacCapConfig
    private var state: MacCapState
    private var policy: AutoPolicy
    private let matcher: CallMatcher
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var session: RecordingSession?
    private var sessionIsAuto = false
    private var callers: [AudioProcess] = []
    private var lastPoll = 0.0
    private var alerting = false
    private var finalizing = 0
    private var lastSaved: String?
    private let finalizeQueue = DispatchQueue(label: "maccap.finalize")
    /// The live-notes controller for the current recording (macOS 26+).
    private var liveNotes: AnyObject?

    init(paths: MacCapPaths, config: MacCapConfig) {
        self.paths = paths
        self.config = config
        state = MacCapState.load(from: paths.state)
        policy = AutoPolicy(startAfter: config.startAfter, stopAfterQuiet: config.stopAfterQuiet)
        matcher = CallMatcher(allowlist: config.effectiveAllowlist, ownPID: getpid())
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Self.recordingCategory,
            actions: [UNNotificationAction(identifier: Self.copyConsentAction, title: "Copy consent message")],
            intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Log.shared.write("notifications \(granted ? "allowed" : "not allowed")")
        }
        Log.shared.write("menu app started; auto \(state.autoPaused ? "paused" : "on"); "
            + "allowlist \(config.effectiveAllowlist.count) entries")
        refreshIcon()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        recoverPending()
        followLoginItem()
        if state.consentAccepted {
            askPermissionsUpFront()
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.askForConsent() else { return }
                self.askPermissionsUpFront()
            }
        }
    }

    // MARK: Consent

    static let recordingCategory = "recording"
    static let copyConsentAction = "copy-consent"

    /// Once, before anything is recorded: the person using this Mac agrees to
    /// record only people who have said yes. MacCap joins no call, so nobody
    /// else is told; asking them is up to the person recording.
    @discardableResult
    private func askForConsent() -> Bool {
        if state.consentAccepted { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Only record people who have said yes"
        alert.informativeText = """
            MacCap records calls on this Mac: your microphone and the call's audio. No bot joins the call, \
            so the other people get no notice from MacCap. Telling them is up to you.

            Ask everyone before you record. In many places recording a call without consent is against the \
            law, and some places need every person on the call to agree.

            Copy consent message (in the menu and on the "Recording" notification) puts a short request on \
            the clipboard for the call's chat. Pause auto-record covers calls you shouldn't record.
            """
        alert.addButton(withTitle: "I'll only record with permission")
        alert.addButton(withTitle: "Quit MacCap")
        guard alert.runModal() == .alertFirstButtonReturn else {
            Log.shared.write("consent declined at first launch; quitting")
            NSApp.terminate(nil)
            return false
        }
        state.consentAccepted = true
        state.save(to: paths.state)
        Log.shared.write("consent: agreed to record only with permission")
        return true
    }

    @objc private func copyConsent() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(config.consent, forType: .string)
        Log.shared.write("consent message copied")
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.content.categoryIdentifier == Self.recordingCategory,
           response.actionIdentifier == Self.copyConsentAction
            || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            DispatchQueue.main.async { self.copyConsent() }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// A login item that was set up from another copy of MacCap (before it
    /// moved to /Applications) is registered again from this one.
    private func followLoginItem() {
        let here = Bundle.main.bundlePath
        guard SMAppService.mainApp.status == .enabled, state.loginItemPath != here else { return }
        do {
            try? SMAppService.mainApp.unregister()
            try SMAppService.mainApp.register()
            state.loginItemPath = here
            state.save(to: paths.state)
            Log.shared.write("login item now starts \(here)")
        } catch {
            Log.shared.write("login item: could not register \(here): \(error)")
        }
    }

    /// Raises the Microphone and System Audio Recording prompts now, while
    /// the person who opened MacCap is at the Mac, rather than in the first
    /// call (where an unanswered system-audio prompt stalls the tap for up
    /// to 3 minutes).
    private func askPermissionsUpFront() {
        if MicPermission.status == .notDetermined {
            MicPermission.request { granted in Log.shared.write("microphone access \(granted ? "allowed" : "refused")") }
        }
        guard !state.systemAudioAsked else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let tap = SystemTap { _, _, _ in }
            do {
                try tap.start()
                Thread.sleep(forTimeInterval: 0.5)
                tap.stop()
                Log.shared.write("system audio permission asked")
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.state.systemAudioAsked = true
                    self.state.save(to: self.paths.state)
                }
            } catch {
                Log.shared.write("system audio permission not answered yet (\(error)); will ask at next launch")
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session else { return .terminateNow }
        Log.shared.write("quit requested while recording; finalizing first")
        self.session = nil
        let dir = session.stop(skipped: false)
        finishLiveNotes { [finalizeQueue, paths, config] _ in
            finalizeQueue.async {
                _ = try? Finalizer.finalize(sessionDir: dir, paths: paths, config: config)
                Log.shared.flush()
                DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) }
            }
        }
        return .terminateLater
    }

    // MARK: Polling

    private func tick() {
        let now = hostSeconds()
        if now - lastPoll >= config.poll {
            lastPoll = now
            poll(now: now)
        }
        refreshIcon()
    }

    private func poll(now: Double) {
        callers = matcher.activeCallers(AudioProcess.all())
        if let session, !callers.isEmpty { session.noteApps(callers) }
        let recording: AutoPolicy.Recording? = session == nil ? nil : (sessionIsAuto ? .auto : .manual)
        switch policy.step(now: now, callActive: !callers.isEmpty, recording: recording, paused: state.autoPaused) {
        case .start:
            startRecording(auto: true)
        case .stop:
            Log.shared.write("call quiet for \(Int(config.stopAfterQuiet)) s; stopping")
            stopRecording(skipped: false)
        case .none:
            break
        }
    }

    // MARK: Recording

    private func startRecording(auto: Bool) {
        guard session == nil else { return }
        // Auto never raises the question mid-call; a manual start may.
        guard state.consentAccepted || (!auto && askForConsent()) else {
            Log.shared.write("not recording: consent not given yet")
            return
        }
        do {
            let session = try RecordingSession(paths: paths, config: config, trigger: auto ? "auto" : "manual",
                                               apps: callers)
            session.onAlert = { [weak self] title, body in
                DispatchQueue.main.async {
                    self?.alerting = true
                    self?.notify(title: title, body: body)
                }
            }
            session.onRecovered = { [weak self] in DispatchQueue.main.async { self?.alerting = false } }
            self.session = session
            sessionIsAuto = auto
            alerting = false
            if config.liveNotesEnabled, #available(macOS 26.0, *) {
                let live = LiveNotesController(config: config, originHost: session.originHost, sessionDir: session.dir)
                live.callApps = callers.map(appName)
                live.onNextCall = { [weak self] in self?.nextCall() }
                live.visibleToSharing = state.visibleToSharing
                live.attach(to: session)
                live.start(showWindow: state.showLiveNotes)
                liveNotes = live
            }
            session.start {}
            nextCallKey = GlobalHotkey(GlobalHotkey.nextCall) { [weak self] in self?.nextCall() }
            let who = callers.first.map { " · \(appName($0))" } ?? ""
            notify(title: "Recording call\(who)",
                   body: "Only with everyone's OK. Click to copy a consent message for the chat; "
                       + "stop or skip from the menu bar.",
                   category: Self.recordingCategory)
        } catch {
            Log.shared.write("cannot start session: \(error)")
            notify(title: "MacCap could not start recording", body: "\(error)")
        }
    }

    private var nextCallKey: GlobalHotkey?

    /// Back-to-back calls: save this one (its meeting-finished window waits
    /// until the next ends) and start recording the next at once.
    @objc private func nextCall() {
        guard session != nil else { return }
        let auto = sessionIsAuto
        Log.shared.write("next call: saving this one and starting the next")
        stopRecording(skipped: false, holdCall: false)
        startRecording(auto: auto)
    }

    private func stopRecording(skipped: Bool, holdCall: Bool = true) {
        guard let session else { return }
        self.session = nil
        alerting = false
        nextCallKey?.unregister()
        nextCallKey = nil
        if skipped { policy.skipCurrentCall() } else if holdCall { policy.holdUntilQuiet() }
        let dir = session.stop(skipped: skipped)
        finalizing += 1
        refreshIcon()
        let auto = sessionIsAuto
        finishLiveNotes { [weak self] live in self?.finalize(dir: dir, skipped: skipped, live: live, auto: auto) }
    }

    /// Let live notes write their last update (bounded), then carry on.
    /// Hands the finished live-notes controller on, for the "meeting finished" window.
    private func finishLiveNotes(then next: @escaping (AnyObject?) -> Void) {
        let live = liveNotes
        liveNotes = nil
        if #available(macOS 26.0, *), let live = live as? LiveNotesController {
            live.finish { next(live) }
        } else {
            next(nil)
        }
    }

    private func finalize(dir: URL, skipped: Bool, live: AnyObject? = nil, auto: Bool = false) {
        finalizeQueue.async { [weak self, paths, config] in
            let result = Result { try Finalizer.finalize(sessionDir: dir, paths: paths, config: config) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.finalizing -= 1
                switch result {
                case .success(let url):
                    self.lastSaved = url.lastPathComponent
                    if !skipped, auto, self.nobodyJoined(live) {
                        // A call app had the mic (Meet's waiting page, a call nobody answered) but
                        // nobody else ever spoke: keep it out of the main folder and any pipeline watching it.
                        if (try? Finalizer.setAside(url, reason: "nobody else spoke", paths: self.paths)) != nil {
                            self.notify(title: "Nobody else joined", body: "Set aside in Skipped, not filed: "
                                + url.lastPathComponent)
                        }
                    } else {
                        if !skipped { self.notify(title: "Call saved", body: url.lastPathComponent) }
                        if !skipped { self.showFinished(live: live, recording: url) }
                    }
                    if self.session == nil { self.showWaitingFinished() }
                case .failure(let error):
                    self.notify(title: "MacCap could not finish a recording",
                                body: "Raw audio is kept in \(dir.lastPathComponent). \(error)")
                }
                self.refreshIcon()
            }
        }
    }

    private func nobodyJoined(_ live: AnyObject?) -> Bool {
        if #available(macOS 26.0, *), let live = live as? LiveNotesController { return live.nobodyElseSpoke }
        return false
    }

    // MARK: Meeting finished

    private var finishedWindows: [NSWindow] = []
    /// Windows for calls that ended while the next was already recording.
    private var waitingFinished: [NSWindow] = []

    private func showWaitingFinished() {
        let windows = waitingFinished
        waitingFinished.removeAll()
        guard !windows.isEmpty else { return }
        NSApp.activate()
        windows.forEach { $0.makeKeyAndOrderFront(nil) }
    }

    private func showFinished(live: AnyObject?, recording: URL) {
        guard config.meetingFinishedEnabled, #available(macOS 26.0, *),
              let live = live as? LiveNotesController,
              let window = FinishedWindow.make(live: live, recording: recording, config: config, onDiscard: { [weak self] in
                  guard let self else { return }
                  if (try? Finalizer.setAside(recording, reason: "discarded after the call", paths: self.paths)) != nil {
                      self.notify(title: "Call discarded", body: "Moved to Skipped, not filed: \(recording.lastPathComponent)")
                  }
              }) else { return }
        window.sharingType = state.visibleToSharing ? .readOnly : .none
        finishedWindows.append(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                               queue: .main) { [weak self] note in
            self?.finishedWindows.removeAll { $0 === note.object as AnyObject }
        }
        if session != nil {
            // Already in the next call: don't take the screen now.
            waitingFinished.append(window)
            Log.shared.write("meeting finished: \(recording.lastPathComponent) waits for the current call to end")
            notify(title: "Next steps saved", body: "They'll open when this call ends.")
            return
        }
        Log.shared.write("meeting finished: showing \(recording.lastPathComponent)")
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func recoverPending() {
        finalizeQueue.async { [paths, config] in
            let results = Finalizer.recoverPending(paths: paths, config: config)
            guard !results.isEmpty else { return }
            var saved = 0, empty = 0, failed = 0
            for item in results {
                switch item.result {
                case .success: saved += 1
                case .failure(let error as FinalizeError) where error.noAudio: empty += 1
                case .failure: failed += 1
                }
            }
            Log.shared.write("recovered \(saved) of \(results.count) unfinished sessions"
                + (empty > 0 ? "; \(empty) held no audio and will not be retried" : ""))
            DispatchQueue.main.async {
                if saved > 0 {
                    self.notify(title: "MacCap recovered \(saved) recording\(saved == 1 ? "" : "s")",
                                body: "Unfinished sessions from before were saved.")
                }
                if failed > 0 {
                    self.notify(title: "MacCap could not finish \(failed) earlier recording\(failed == 1 ? "" : "s")",
                                body: "Raw audio is kept in \(self.paths.sessions.path); it will try again next launch.")
                }
            }
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: statusText(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if alerting {
            let warning = NSMenuItem(title: "⚠︎ Not hearing the other side", action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
        }
        menu.addItem(.separator())
        menu.addItem(item("Copy consent message", #selector(copyConsent)))
        if session == nil {
            menu.addItem(item("Start recording now", #selector(startNow)))
        } else {
            menu.addItem(item("Stop recording", #selector(stopNow)))
            menu.addItem(item("Next call (save this, start a new one)  ⌃⌥N", #selector(nextCall)))
            menu.addItem(item("Stop and skip this call", #selector(skipNow)))
            if liveNotes != nil { menu.addItem(item("Show live notes", #selector(showLiveNotesNow))) }
        }
        menu.addItem(.separator())
        menu.addItem(item(state.autoPaused ? "Resume auto-record" : "Pause auto-record", #selector(toggleAuto)))
        if config.liveNotesEnabled, #available(macOS 26.0, *) {
            let sharing = item("Show MacCap in screenshots and screen sharing", #selector(toggleSharing))
            sharing.state = state.visibleToSharing ? .on : .off
            menu.addItem(sharing)
            let notes = item("Open live notes when recording", #selector(toggleLiveNotesWindow))
            notes.state = state.showLiveNotes ? .on : .off
            menu.addItem(notes)
        }
        let login = item("Start at login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Open recordings folder", #selector(openFolder)))
        menu.addItem(item("Open log", #selector(openLog)))
        menu.addItem(.separator())
        menu.addItem(item("Quit MacCap", #selector(quit)))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func statusText() -> String {
        if let session {
            let who = callers.first.map { " · \(appName($0))" } ?? ""
            if sessionIsAuto, let left = policy.stopsIn(now: hostSeconds()) {
                return "Recording \(format(session.elapsed)) · call ended, saving in \(Int(left.rounded(.up))) s"
            }
            return "Recording \(format(session.elapsed))\(who)\(sessionIsAuto ? "" : " (manual)")"
        }
        if finalizing > 0 { return "Saving recording…" }
        if state.autoPaused { return "Auto-record paused" }
        if policy.skipping { return "Skipping this call" }
        if policy.holding { return "Stopped · records the next call" }
        return "Watching for calls" + (lastSaved.map { " · last: \($0)" } ?? "")
    }

    @objc private func startNow() { startRecording(auto: false) }
    @objc private func stopNow() { stopRecording(skipped: false) }
    @objc private func skipNow() { stopRecording(skipped: true) }

    @objc private func showLiveNotesNow() {
        if #available(macOS 26.0, *) { (liveNotes as? LiveNotesController)?.show() }
    }

    @objc private func toggleSharing() {
        state.visibleToSharing.toggle()
        state.save(to: paths.state)
        if #available(macOS 26.0, *) { (liveNotes as? LiveNotesController)?.visibleToSharing = state.visibleToSharing }
        for window in finishedWindows + waitingFinished {
            window.sharingType = state.visibleToSharing ? .readOnly : .none
        }
        Log.shared.write("windows \(state.visibleToSharing ? "shown in" : "hidden from") screenshots and sharing")
    }

    @objc private func toggleLiveNotesWindow() {
        state.showLiveNotes.toggle()
        state.save(to: paths.state)
    }

    @objc private func toggleAuto() {
        state.autoPaused.toggle()
        state.save(to: paths.state)
        Log.shared.write("auto-record \(state.autoPaused ? "paused" : "resumed")")
        refreshIcon()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                Log.shared.write("login item removed")
            } else {
                try SMAppService.mainApp.register()
                state.loginItemPath = Bundle.main.bundlePath
                state.save(to: paths.state)
                Log.shared.write("login item added")
            }
        } catch {
            notify(title: "Could not change Start at login", body: "\(error.localizedDescription)")
        }
    }

    @objc private func openFolder() { NSWorkspace.shared.open(paths.audio) }
    @objc private func openLog() { NSWorkspace.shared.open(paths.log) }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Icon and notifications

    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        var color: NSColor?
        if session != nil {
            symbol = alerting ? "exclamationmark.triangle.fill" : "record.circle.fill"
            color = alerting ? .systemOrange : .systemRed
            button.title = " " + format(session!.elapsed)
        } else {
            symbol = state.autoPaused ? "pause.circle" : (finalizing > 0 ? "arrow.down.circle" : "waveform")
            button.title = ""
        }
        var image = NSImage(systemSymbolName: symbol, accessibilityDescription: "MacCap")
        if let color, let tinted = image?.withSymbolConfiguration(.init(paletteColors: [color])) {
            image = tinted
            image?.isTemplate = false
        } else {
            image?.isTemplate = true
        }
        button.image = image
        button.imagePosition = .imageLeft
    }

    private func notify(title: String, body: String, category: String? = nil) {
        Log.shared.write("notify: \(title) — \(body)")
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let category { content.categoryIdentifier = category }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString,
                                                                     content: content, trigger: nil))
    }

    private func appName(_ process: AudioProcess) -> String {
        if let bundleID = process.bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return process.displayName
    }

    private func format(_ seconds: Double) -> String {
        let total = Int(seconds)
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}
