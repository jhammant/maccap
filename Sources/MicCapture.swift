import AVFoundation
import CoreAudio
import Foundation

enum MicPermission {
    static var status: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    /// Asks once when undecided. Calls back on an arbitrary queue.
    static func request(_ done: @escaping (Bool) -> Void) {
        switch status {
        case .authorized: done(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: .audio, completionHandler: done)
        default: done(false)
        }
    }
}

/// The default input device through AVAudioEngine, downmixed to mono.
/// A device or format change (AirPods connecting, HFP switching on) stops the
/// engine; it is rebuilt and the stem starts a new segment.
final class MicCapture {
    typealias SampleHandler = (_ samples: [Float], _ sampleRate: Double, _ startHost: Double) -> Void

    private var engine = AVAudioEngine()
    private let onSamples: SampleHandler
    private let onRouteChange: (_ route: String) -> Void
    private var observer: NSObjectProtocol?
    private var running = false
    private let control = DispatchQueue(label: "maccap.mic.control")
    private(set) var route = ""

    init(onSamples: @escaping SampleHandler, onRouteChange: @escaping (String) -> Void) {
        self.onSamples = onSamples
        self.onRouteChange = onRouteChange
    }

    func start() throws {
        try control.sync { try startLocked() }
    }

    func stop() {
        control.sync {
            running = false
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    private func startLocked() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "maccap.mic", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no input device (format \(format))"])
        }
        let handler = onSamples
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, when in
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            let frames = Int(buffer.frameLength)
            let count = Int(buffer.format.channelCount)
            var mono = [Float](repeating: 0, count: frames)
            if buffer.format.isInterleaved {
                let samples = channels[0]
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<count { sum += samples[frame * count + channel] }
                    mono[frame] = sum / Float(count)
                }
            } else {
                for channel in 0..<count {
                    let samples = channels[channel]
                    for frame in 0..<frames { mono[frame] += samples[frame] }
                }
                if count > 1 { for frame in 0..<frames { mono[frame] /= Float(count) } }
            }
            let start = when.isHostTimeValid
                ? hostSeconds(when.hostTime)
                : hostSeconds() - Double(frames) / buffer.format.sampleRate
            handler(mono, buffer.format.sampleRate, start)
        }
        engine.prepare()
        try engine.start()
        running = true
        let device = AudioHAL.defaultDevice(input: true)
        route = "\(AudioHAL.deviceName(device) ?? "unknown input") (\(AudioHAL.transportName(device)), "
            + "\(Int(format.sampleRate)) Hz, \(format.channelCount) ch)"
        Log.shared.write("mic: started on \(route)")
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                self?.control.asyncAfter(deadline: .now() + 0.3) { self?.restartAfterChange() }
            }
        }
    }

    private func restartAfterChange() {
        guard running else { return }
        Log.shared.write("mic: configuration changed, rebuilding the engine")
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine = AVAudioEngine()
        for attempt in 1...5 {
            do {
                try startLocked()
                onRouteChange(route)
                return
            } catch {
                Log.shared.write("mic: restart attempt \(attempt) failed: \(error.localizedDescription)")
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        running = false
        Log.shared.write("mic: gave up restarting; the mic stem stops here")
    }
}
