// Ported from Minutes (https://github.com/silverstein/minutes),
// crates/core/src/remote_silence.rs, MIT License,
// Copyright (c) 2026 Mat Silverstein. See THIRD_PARTY_NOTICES.md.

import Foundation

/// Notices, within about a minute, that a call recording is hearing the
/// local mic but never the other side: a refused System Audio Recording
/// permission (the tap then delivers exact zeros), the call playing on
/// another device, or a tap that lost its source.
///
///            silent system + mic speech for `neverHeardWindow`
///   armed ───────────────────────────────────────────────────▶ alerted
///     ▲     (or `dropoutWindow` once remote audio was heard)       │
///     └──────── remote audio audible again for `rearmAudible` ─────┘
///
/// Time only accumulates across observed samples, and mic speech is required,
/// so a recording waiting for a call to connect, or a quiet room, never alarms.
struct RemoteSilenceDetector {
    struct Thresholds {
        var systemAudibleLevel: UInt32 = 2
        var micSpeechLevel: UInt32 = 8
        var neverHeardWindow = 60.0
        var dropoutWindow = 120.0
        var minMicSpeech = 15.0
        var remoteHeardAudible = 3.0
        var rearmAudible = 5.0
        var renotifyCooldown = 600.0
        var maxStep = 1.0
    }

    enum Kind: String, Codable { case neverHeard = "never-heard", lost }

    enum Event: Equatable {
        case alert(Kind)
        case recovered
    }

    private enum Phase { case armed, alerted }

    let thresholds: Thresholds
    private var phase = Phase.armed
    private var lastObservedAt: Double?
    private var windowObserved = 0.0
    private var windowMicSpeech = 0.0
    private var windowSystemAudible = 0.0
    private var rearmSystemAudible = 0.0
    private(set) var remoteHeard = false
    private(set) var alertsFired = 0
    private var lastAlertAt: Double?

    init(thresholds: Thresholds = Thresholds()) { self.thresholds = thresholds }

    var isAlerting: Bool { phase == .alerted }

    mutating func observe(now: Double, micLevel: UInt32, systemLevel: UInt32) -> Event? {
        let previous = lastObservedAt
        lastObservedAt = now
        guard let previous else { return nil }
        let step = min(max(0, now - previous), thresholds.maxStep)
        guard step > 0 else { return nil }

        if systemLevel >= thresholds.systemAudibleLevel {
            windowSystemAudible += step
            if phase == .alerted { rearmSystemAudible += step }
            if windowSystemAudible >= thresholds.remoteHeardAudible {
                remoteHeard = true
                resetWindow()
            }
            if phase == .alerted, rearmSystemAudible >= thresholds.rearmAudible {
                phase = .armed
                rearmSystemAudible = 0
                resetWindow()
                return .recovered
            }
            return nil
        }

        windowObserved += step
        if micLevel >= thresholds.micSpeechLevel { windowMicSpeech += step }
        guard phase == .armed else { return nil }
        let window = remoteHeard ? thresholds.dropoutWindow : thresholds.neverHeardWindow
        guard windowObserved >= window, windowMicSpeech >= thresholds.minMicSpeech else { return nil }
        if let lastAlertAt, now - lastAlertAt < thresholds.renotifyCooldown { return nil }
        phase = .alerted
        rearmSystemAudible = 0
        alertsFired += 1
        lastAlertAt = now
        return .alert(remoteHeard ? .lost : .neverHeard)
    }

    private mutating func resetWindow() {
        windowObserved = 0
        windowMicSpeech = 0
        windowSystemAudible = 0
    }

    static func message(_ kind: Kind, heardAudio: Bool) -> (title: String, body: String) {
        let title = "MacCap isn't hearing the other side of this call"
        switch (kind, heardAudio) {
        case (.neverHeard, false):
            return (title, "No call audio for over a minute while you were speaking, so only your mic is being "
                + "recorded. Check MacCap is allowed under System Settings › Privacy & Security › Screen & "
                + "System Audio Recording, and that the call is playing on this Mac.")
        case (.neverHeard, true):
            return (title, "No call audio for over a minute while you were speaking. Check the call is playing "
                + "on this Mac, not on your phone or another device.")
        case (.lost, _):
            return (title, "Call audio stopped for two minutes while you were speaking. If they are talking, "
                + "their side is not being recorded. Check your output device.")
        }
    }
}
