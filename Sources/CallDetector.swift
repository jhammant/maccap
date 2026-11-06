import Foundation

/// Which audio processes count as a call: an allowlisted app (by bundle-ID
/// prefix, or executable name for daemons) that is using the microphone.
struct CallMatcher {
    let allowlist: [String]
    let ownPID: pid_t

    func matches(bundleID: String?, name: String) -> Bool {
        if let bundleID, allowlist.contains(where: { bundleID.hasPrefix($0) }) { return true }
        return !name.isEmpty && allowlist.contains(name)
    }

    func activeCallers(_ processes: [AudioProcess]) -> [AudioProcess] {
        processes.filter { $0.pid != ownPID && $0.runningInput && matches(bundleID: $0.bundleID, name: $0.name) }
    }
}

/// When to start and stop automatic recordings. Pure state, driven by poll
/// results with explicit timestamps, so the self-test can replay it.
struct AutoPolicy {
    enum Action: Equatable { case none, start, stop }
    enum Recording { case auto, manual }

    let startAfter: Double
    let stopAfterQuiet: Double
    private var activeSince: Double?
    private var quietSince: Double?
    /// Set by "Stop and skip this call": ignore the call until it ends.
    private(set) var skipping = false
    /// Set by "Stop recording": don't start again while the same call app
    /// still has the mic (a Meet tab left open after the call).
    private(set) var holding = false

    init(startAfter: Double, stopAfterQuiet: Double) {
        self.startAfter = startAfter
        self.stopAfterQuiet = stopAfterQuiet
    }

    /// Seconds until an automatic recording stops, once the call has gone quiet.
    func stopsIn(now: Double) -> Double? {
        guard !skipping, !holding, let quietSince else { return nil }
        return max(0, stopAfterQuiet - (now - quietSince))
    }

    mutating func holdUntilQuiet() {
        holding = true
        activeSince = nil
    }

    mutating func skipCurrentCall() {
        skipping = true
        activeSince = nil
    }

    /// `recording` is nil when idle, otherwise whether the running session
    /// was started automatically. Manual sessions never auto-stop.
    mutating func step(now: Double, callActive: Bool, recording: Recording?, paused: Bool) -> Action {
        if callActive {
            quietSince = nil
            if activeSince == nil { activeSince = now }
        } else {
            activeSince = nil
            if quietSince == nil { quietSince = now }
        }
        let quietLongEnough = quietSince.map { now - $0 >= stopAfterQuiet } ?? false
        if skipping || holding {
            if quietLongEnough {
                skipping = false
                holding = false
            }
            return .none
        }
        if let recording {
            return recording == .auto && quietLongEnough ? .stop : .none
        }
        if paused { return .none }
        if let activeSince, now - activeSince >= startAfter { return .start }
        return .none
    }
}
