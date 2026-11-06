import AppKit
import AVFoundation

/// `MacCap demo FILE`: plays a stereo recording (left: you, right: the call)
/// into the live-notes window at its own pace, then opens the meeting-finished
/// window, so MacCap can be tried, or shown, without recording anyone. Nothing
/// is recorded and nothing is saved in the recordings folder.
final class DemoCommand: NSObject, NSApplicationDelegate {
    let file: URL
    /// 2 plays twice as fast.
    let speed: Double

    init(file: URL, speed: Double) {
        self.file = file
        self.speed = max(0.25, speed)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard #available(macOS 26.0, *) else {
            print("the demo needs macOS 26 or later (live notes)")
            exit(2)
        }
        Task { @MainActor in
            do {
                try await self.play()
            } catch {
                print("error: \(error)")
                exit(2)
            }
        }
    }

    @available(macOS 26.0, *)
    @MainActor
    private func play() async throws {
        let audio = try AVAudioFile(forReading: file)
        let format = audio.processingFormat
        guard format.channelCount == 2 else {
            throw NotesModelError(description: "expected a stereo file: left channel you, right channel the call")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maccap-demo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let live = LiveNotesController(config: config, originHost: 0, sessionDir: dir)
        live.visibleToSharing = true  // a demo is meant to be seen and recorded
        live.startAssist()
        NSApp.activate()
        live.show()
        guard await live.prepare() else { exit(2) }
        print("playing \(file.lastPathComponent) (\(String(format: "%.0f", Double(audio.length) / format.sampleRate)) s"
            + (speed == 1 ? "" : " at \(speed)×") + ")")
        let rate = format.sampleRate
        let chunk = AVAudioFrameCount(rate / 10)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { exit(2) }
        var position = 0.0
        while audio.framePosition < audio.length {
            try audio.read(into: buffer, frameCount: chunk)
            let n = Int(buffer.frameLength)
            guard n > 0, let data = buffer.floatChannelData else { break }
            live.feed(.mic, Array(UnsafeBufferPointer(start: data[0], count: n)), rate: rate, startHost: position)
            live.feed(.system, Array(UnsafeBufferPointer(start: data[1], count: n)), rate: rate, startHost: position)
            position += Double(n) / rate
            try await Task.sleep(for: .seconds(Double(n) / rate / speed))
        }
        try await Task.sleep(for: .seconds(2))  // let the last words reach the transcript
        print("call over; writing the notes")
        live.finish(timeout: 120) {
            printNotes(live.finalNotes)
            guard config.meetingFinishedEnabled,
                  let window = FinishedWindow.make(live: live, recording: self.file, config: config, onDiscard: {}) else {
                exit(0)
            }
            window.sharingType = .readOnly
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                   queue: .main) { _ in exit(0) }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            print("close the window to finish")
        }
    }
}
