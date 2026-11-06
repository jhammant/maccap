import AudioToolbox
import AVFoundation
import Foundation

/// Positions a buffer on the shared stem timeline. Both stems are laid out on
/// host time from one origin, so the system stem stays aligned with the mic
/// stem however late its source started, however long it stalled, and
/// however its clock drifts. Pure arithmetic.
///
/// Adapted from Minutes' StemPlacement (MIT, Copyright (c) 2026 Mat
/// Silverstein); see THIRD_PARTY_NOTICES.md.
struct StemPlacement: Equatable {
    /// Beyond this the stem is not drifting but has a gap or a fresh start,
    /// and is moved in one step.
    static let jumpThreshold = 0.25
    /// A stem that runs ahead is trimmed at most this much per buffer, so a
    /// correction cuts a couple of milliseconds, never a word. A stem that
    /// falls behind is padded in one step.
    static let driftStep = 0.002
    /// Offsets smaller than this are jitter and left alone.
    static let tolerance = 0.05

    var padSeconds = 0.0
    var dropSeconds = 0.0

    static func place(bufferStart: Double, bufferSeconds: Double, written: Double,
                      tolerance: Double = StemPlacement.tolerance, align: Bool = false) -> StemPlacement {
        let delta = bufferStart - written
        guard abs(delta) > tolerance else { return StemPlacement() }
        if delta > 0 { return StemPlacement(padSeconds: delta) }
        let whole = align || -delta > jumpThreshold
        return StemPlacement(dropSeconds: min(whole ? -delta : driftStep, bufferSeconds))
    }
}

/// Health counters for one stem. Levels use a 0-100 scale (`rms * 2000`):
/// 2 is roughly -60 dBFS (audible), 8 roughly -48 dBFS (speech).
struct StemStats: Codable {
    var buffers = 0
    var sourceFrames = 0
    var seconds = 0.0
    var nonZeroBuffers = 0
    var audibleSeconds = 0.0
    var speechSeconds = 0.0
    var peakLevel: UInt32 = 0
    var sumSquares = 0.0
    var paddedSeconds = 0.0
    var droppedSeconds = 0.0
    var firstBufferOffset: Double?
    var sampleRates: [Double] = []
    /// Length of the stem on the timeline (fed + padded - dropped).
    var writtenSeconds = 0.0

    static let audibleLevel: UInt32 = 2
    static let speechLevel: UInt32 = 8

    var rmsDBFS: Double? {
        guard sourceFrames > 0, sumSquares > 0 else { return nil }
        return 10 * log10(sumSquares / Double(sourceFrames))
    }
    var heardAudio: Bool { nonZeroBuffers > 0 && audibleSeconds >= 1 }

    enum CodingKeys: String, CodingKey {
        case buffers, seconds
        case sourceFrames = "source_frames"
        case nonZeroBuffers = "non_zero_buffers"
        case audibleSeconds = "audible_seconds"
        case speechSeconds = "speech_seconds"
        case peakLevel = "peak_level"
        case sumSquares = "sum_squares"
        case paddedSeconds = "padded_seconds"
        case droppedSeconds = "dropped_seconds"
        case firstBufferOffset = "first_buffer_offset"
        case sampleRates = "sample_rates"
        case writtenSeconds = "written_seconds"
    }
}

func audioLevel(rms: Float) -> UInt32 {
    UInt32(min(100.0, max(0.0, Double(rms) * 2000.0)))
}

struct SegmentRecord: Codable {
    var file: String
    var startSeconds: Double
    var reason: String
    var route: String?

    enum CodingKeys: String, CodingKey {
        case file, reason, route
        case startSeconds = "start_seconds"
    }
}

/// Writes one stem (mic or system) as mono 48 kHz AAC ADTS segments. ADTS
/// frames are self-delimiting, so a crash loses at most the last frame.
/// Everything runs on the writer's own serial queue, off the audio thread.
final class StemWriter {
    static let outputRate = 48_000.0
    static let converterChunk = 1024

    let name: String
    private let dir: URL
    private let originHost: Double
    private let queue: DispatchQueue
    private let onSegment: (SegmentRecord) -> Void

    private var file: ExtAudioFileRef?
    private var segmentCount = 0
    private var written = 0.0
    private var converter: AVAudioConverter?
    private var converterRate = 0.0
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: StemWriter.outputRate,
                                             channels: 1, interleaved: false)!
    private var pendingAlign = true
    private var outputFrames = 0
    /// Set by close(); later buffers (a tap still winding down) are ignored.
    private var closed = false

    private let statsLock = NSLock()
    private var stats = StemStats()
    private var tickPeak: UInt32 = 0
    private var lastBufferHost: Double?

    init(name: String, dir: URL, originHost: Double, onSegment: @escaping (SegmentRecord) -> Void) {
        self.name = name
        self.dir = dir
        self.originHost = originHost
        self.onSegment = onSegment
        queue = DispatchQueue(label: "maccap.stem.\(name)", qos: .userInitiated)
    }

    // MARK: Called from capture threads

    func append(_ samples: [Float], rate: Double, startHost: Double) {
        guard !samples.isEmpty, rate > 0 else { return }
        var sum: Float = 0
        var nonZero = false
        for sample in samples {
            sum += sample * sample
            if sample != 0 { nonZero = true }
        }
        let rms = (sum / Float(samples.count)).squareRoot()
        let level = audioLevel(rms: rms)
        let seconds = Double(samples.count) / rate
        statsLock.withLock {
            stats.buffers += 1
            stats.sourceFrames += samples.count
            stats.seconds += seconds
            stats.sumSquares += Double(sum)
            if nonZero { stats.nonZeroBuffers += 1 }
            if level >= StemStats.audibleLevel { stats.audibleSeconds += seconds }
            if level >= StemStats.speechLevel { stats.speechSeconds += seconds }
            stats.peakLevel = max(stats.peakLevel, level)
            if stats.firstBufferOffset == nil { stats.firstBufferOffset = startHost - originHost }
            if !stats.sampleRates.contains(rate) { stats.sampleRates.append(rate) }
            tickPeak = max(tickPeak, level)
            lastBufferHost = startHost
        }
        queue.async { [self] in place(samples, rate: rate, startHost: startHost) }
    }

    /// Closes the current segment; the next buffer opens a new one.
    /// `align` lets the next buffer snap to the timeline in one step.
    func newSegment(reason: String, route: String?) {
        queue.async { [self] in
            guard !closed else { return }
            closeFile()
            openSegment(reason: reason, route: route)
            pendingAlign = true
        }
    }

    // MARK: Readers

    /// Peak level since the last call, for the once-a-second health tick.
    func takeTickPeak() -> UInt32 {
        statsLock.withLock {
            let peak = tickPeak
            tickPeak = 0
            return peak
        }
    }

    var snapshot: StemStats { statsLock.withLock { stats } }
    var lastBufferAt: Double? { statsLock.withLock { lastBufferHost } }

    // MARK: Lifecycle

    func open(reason: String, route: String?) {
        queue.sync { openSegment(reason: reason, route: route) }
    }

    /// Flushes and closes. Blocks until every queued buffer is written.
    func close() -> Double {
        queue.sync {
            closeFile()
            closed = true
            if ProcessInfo.processInfo.environment["MACCAP_DEBUG"] != nil {
                print("debug \(name): written \(written) s, output \(Double(outputFrames) / Self.outputRate) s")
            }
            return written
        }
    }

    // MARK: Writer queue

    private func place(_ samples: [Float], rate: Double, startHost: Double) {
        guard !closed else { return }
        if file == nil { openSegment(reason: "reopen", route: nil) }
        var samples = samples
        let bufferStart = startHost - originHost
        let placement = StemPlacement.place(bufferStart: bufferStart, bufferSeconds: Double(samples.count) / rate,
                                            written: written, align: pendingAlign)
        pendingAlign = false
        if placement.padSeconds > 0 {
            writeSilence(seconds: placement.padSeconds, rate: rate)
            statsLock.withLock { stats.paddedSeconds += placement.padSeconds }
        }
        if placement.dropSeconds > 0 {
            let drop = min(samples.count, Int((placement.dropSeconds * rate).rounded()))
            samples.removeFirst(drop)
            statsLock.withLock { stats.droppedSeconds += Double(drop) / rate }
        }
        write(samples, rate: rate)
    }

    private func writeSilence(seconds: Double, rate: Double) {
        var remaining = Int((seconds * rate).rounded())
        let chunk = Int(rate)
        while remaining > 0 {
            let count = min(chunk, remaining)
            write([Float](repeating: 0, count: count), rate: rate)
            remaining -= count
        }
    }

    private func write(_ samples: [Float], rate: Double) {
        guard !samples.isEmpty else { return }
        written += Double(samples.count) / rate
        let total = written
        statsLock.withLock { stats.writtenSeconds = total }
        let output = resample(samples, from: rate)
        writeOutput(output)
    }

    private func resample(_ samples: [Float], from rate: Double) -> [Float] {
        if rate == Self.outputRate {
            if converter != nil { writeOutput(flushConverter()) }
            return samples
        }
        if converter == nil || converterRate != rate {
            if converter != nil { writeOutput(flushConverter()) }
            let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1,
                                      interleaved: false)!
            converter = AVAudioConverter(from: input, to: outputFormat)
            converterRate = rate
        }
        guard let converter else { return [] }
        // AVAudioConverter takes about 4096 frames per call and quietly holds
        // back the rest of a larger buffer, which shifts the stem later after
        // every long silence pad. Small chunks keep its latency at ~1 ms.
        var output: [Float] = []
        output.reserveCapacity(Int(Double(samples.count) * Self.outputRate / rate) + 64)
        var offset = 0
        while offset < samples.count {
            let count = min(Self.converterChunk, samples.count - offset)
            output += convertChunk(samples, offset: offset, count: count, converter: converter, rate: rate)
            offset += count
        }
        return output
    }

    private func convertChunk(_ samples: [Float], offset: Int, count: Int, converter: AVAudioConverter,
                              rate: Double) -> [Float] {
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: converter.inputFormat,
                                              frameCapacity: AVAudioFrameCount(count)) else { return [] }
        inBuffer.frameLength = AVAudioFrameCount(count)
        samples.withUnsafeBufferPointer { source in
            inBuffer.floatChannelData![0].update(from: source.baseAddress! + offset, count: count)
        }
        let capacity = AVAudioFrameCount(Double(count) * Self.outputRate / rate) + 256
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }
        var given = false
        var error: NSError?
        // Reuse needs .noDataNow: after .endOfStream a converter returns nothing.
        _ = converter.convert(to: outBuffer, error: &error) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return inBuffer
        }
        if let error { Log.shared.write("\(name): resample error \(error)") }
        return Array(UnsafeBufferPointer(start: outBuffer.floatChannelData![0], count: Int(outBuffer.frameLength)))
    }

    /// Drains the converter's tail and drops it.
    private func flushConverter() -> [Float] {
        defer {
            converter = nil
            converterRate = 0
        }
        guard let converter,
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else { return [] }
        var error: NSError?
        _ = converter.convert(to: outBuffer, error: &error) { _, status in
            status.pointee = .endOfStream
            return nil
        }
        return Array(UnsafeBufferPointer(start: outBuffer.floatChannelData![0], count: Int(outBuffer.frameLength)))
    }

    private func writeOutput(_ samples: [Float]) {
        guard !samples.isEmpty, let file else { return }
        var samples = samples
        let status = samples.withUnsafeMutableBufferPointer { pointer -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 1, mDataByteSize: UInt32(pointer.count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(pointer.baseAddress)))
            return ExtAudioFileWrite(file, UInt32(pointer.count), &list)
        }
        if status != noErr { Log.shared.write("\(name): ExtAudioFileWrite failed \(status)") }
        outputFrames += samples.count
    }

    private func openSegment(reason: String, route: String?) {
        segmentCount += 1
        let fileName = String(format: "%@-%03d.aac", name, segmentCount)
        let url = dir.appendingPathComponent(fileName)
        // The manifest learns of the segment before audio lands in it.
        onSegment(SegmentRecord(file: fileName, startSeconds: written, reason: reason, route: route))
        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: Self.outputRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        var ref: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(url as CFURL, kAudioFileAAC_ADTSType, &fileFormat, nil,
                                               AudioFileFlags.eraseFile.rawValue, &ref)
        guard status == noErr, let ref else {
            Log.shared.write("\(name): cannot create \(fileName) (\(status))")
            return
        }
        var client = AudioStreamBasicDescription(
            mSampleRate: Self.outputRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
            mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        status = ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ClientDataFormat,
                                         UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard status == noErr else {
            Log.shared.write("\(name): cannot set client format (\(status))")
            ExtAudioFileDispose(ref)
            return
        }
        file = ref
        Log.shared.write("\(name): segment \(fileName) at \(String(format: "%.2f", written)) s (\(reason))")
    }

    private func closeFile() {
        if converter != nil { writeOutput(flushConverter()) }
        if let file { ExtAudioFileDispose(file) }
        file = nil
    }
}
