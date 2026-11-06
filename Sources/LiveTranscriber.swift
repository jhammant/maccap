import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Live transcription of one side of the call with Apple's on-device
/// SpeechTranscriber (macOS 26+). Samples arrive from MacCap's capture
/// callbacks with their host time; each buffer is stamped with its time on
/// the recording's timeline, so lines line up with the saved file even
/// across gaps. Never touches the recording itself: if this fails, the call
/// is still recorded.
@available(macOS 26.0, *)
final class LiveTranscriber {
    let stem: LiveStem
    /// Final lines, and lines still in progress (`isFinal` false).
    var onLine: ((_ line: LiveLine, _ isFinal: Bool) -> Void)?

    private let originHost: Double
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let queue: DispatchQueue
    private var format: AVAudioFormat?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var converterRate = 0.0
    private var nextExpected: Double?  // recording seconds where the next sample would follow on
    private var results: Task<Void, Never>?
    private var pending: AsyncStream<AnalyzerInput>?

    init(stem: LiveStem, locale: Locale, originHost: Double) {
        self.stem = stem
        self.originHost = originHost
        transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                        reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
        analyzer = SpeechAnalyzer(modules: [transcriber])
        queue = DispatchQueue(label: "maccap.live.\(stem.rawValue)")
    }

    /// The supported locale nearest `identifier` (else the Mac's own), with its
    /// speech model downloaded if it isn't installed yet.
    static func prepareLocale(_ identifier: String?) async throws -> Locale {
        let wanted = identifier.map(Locale.init(identifier:)) ?? Locale.current
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
            throw NotesModelError(description: "live transcription is not available for \(wanted.identifier)")
        }
        let probe = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
            Log.shared.write("live notes: downloading the \(locale.identifier) speech model")
            try await request.downloadAndInstall()
        }
        return locale
    }

    /// Sets up the input stream and the results reader; samples fed after
    /// this are kept. `run` then starts the analysis.
    func prepare() async throws {
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NotesModelError(description: "no audio format for live transcription")
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        queue.sync {
            self.format = format
            self.continuation = continuation
        }
        let stem = self.stem
        results = Task { [transcriber, weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let line = LiveLine(stem: stem, start: result.range.start.seconds,
                                        end: result.range.end.seconds, text: text)
                    self?.onLine?(line, result.isFinal)
                }
            } catch {
                Log.shared.write("live notes: \(stem.rawValue) transcription stopped: \(error)")
            }
        }
        pending = stream
    }

    func run() async throws {
        guard let stream = pending else { return }
        pending = nil
        try await analyzer.start(inputSequence: stream)
    }

    /// Called from capture threads; returns at once. Converted in pieces of
    /// at most 1,024 frames: AVAudioConverter quietly holds back part of a
    /// larger input when it resamples (see StemWriter.converterChunk).
    func feed(_ samples: [Float], rate: Double, startHost: Double) {
        guard !samples.isEmpty, rate > 0 else { return }
        queue.async {
            var offset = 0
            while offset < samples.count {
                let count = min(1024, samples.count - offset)
                let piece = Array(samples[offset..<(offset + count)])
                self.convertAndYield(piece, rate: rate, at: startHost - self.originHost + Double(offset) / rate)
                offset += count
            }
        }
    }

    private func convertAndYield(_ samples: [Float], rate: Double, at seconds: Double) {
        guard let format, let continuation,
              let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1,
                                        interleaved: false),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        inBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { inBuffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }

        if converter == nil || converterRate != rate {
            converter = AVAudioConverter(from: input, to: format)
            converterRate = rate
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(samples.count) * format.sampleRate / rate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return inBuffer
        }
        guard error == nil, out.frameLength > 0 else { return }

        // Stamp the buffer only where the timeline jumps (first buffer, a gap,
        // a stall); otherwise it follows on from the last one.
        let duration = Double(samples.count) / rate
        var stamp: CMTime? = nil
        if let expected = nextExpected, abs(seconds - expected) < 0.25 {
            nextExpected = expected + duration
        } else {
            stamp = CMTime(seconds: max(0, seconds), preferredTimescale: 48_000)
            nextExpected = seconds + duration
        }
        continuation.yield(AnalyzerInput(buffer: out, bufferStartTime: stamp))
    }

    /// Ends the input and waits for the last lines.
    func finish() async {
        let continuation: AsyncStream<AnalyzerInput>.Continuation? = queue.sync { self.continuation }
        continuation?.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            Log.shared.write("live notes: \(stem.rawValue) finish failed: \(error)")
        }
        await results?.value
    }
}
