// Adapted from Minutes (https://github.com/silverstein/minutes),
// tauri/src-tauri/src/system_audio_tap.swift, MIT License,
// Copyright (c) 2026 Mat Silverstein. See THIRD_PARTY_NOTICES.md.
//
// Changes: no ScreenCaptureKit witness or source arbiter; optional narrowing
// to call apps by bundle ID (macOS 26+); frame counting for the measured-rate
// check lives in the recorder.

import AudioToolbox
import CoreAudio
import Dispatch
import Foundation
import os

struct SystemTapFailure: Error, CustomStringConvertible {
    let stage: String
    let status: OSStatus
    var description: String { "\(stage) failed (OSStatus \(status))" }
}

private func checkStatus(_ status: OSStatus, _ stage: String) throws {
    guard status == noErr else { throw SystemTapFailure(stage: stage, status: status) }
}

/// One Core Audio process tap plus the private aggregate device that exposes
/// it as an input stream. A global tap reads process output at the HAL, so it
/// hears browser calls, Zoom, and also FaceTime (avconferenced) and iPhone
/// calls answered on the Mac (callservicesd), which ScreenCaptureKit cannot.
///
/// Not reusable: the recorder builds a new instance for every start or
/// rebuild, and calls `start`/`stop` from one control queue.
final class SystemTap {
    /// Mono samples, their sample rate, and the host time of the first one.
    typealias SampleHandler = (_ samples: [Float], _ sampleRate: Double, _ startHost: Double) -> Void

    private let ioQueue = DispatchQueue(label: "maccap.system-tap.io", qos: .userInitiated)
    private let onSamples: SampleHandler
    private let narrowToBundleIDs: [String]
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var started = false
    private var rateListener: AudioObjectPropertyListenerBlock?
    private let listenerQueue = DispatchQueue(label: "maccap.system-tap.rate")
    /// The IOProc delivers at the aggregate's current rate, which drops to
    /// 16 kHz when a Bluetooth headset enters HFP for a call. A rate fixed at
    /// start played the stem 3x fast in Minutes (#1165), so it is read live.
    private let sampleRate = OSAllocatedUnfairLock(initialState: 0.0)
    private(set) var format = AudioStreamBasicDescription()
    private(set) var narrowed = false

    var currentSampleRate: Double { sampleRate.withLock { $0 } }

    init(narrowToBundleIDs: [String] = [], onSamples: @escaping SampleHandler) {
        self.narrowToBundleIDs = narrowToBundleIDs
        self.onSamples = onSamples
    }

    deinit { stop() }

    func start() throws {
        do {
            try createTap()
            try readFormat()
            try createAggregate()
            seedAndWatchSampleRate()
            try startIO()
        } catch {
            stop()
            throw error
        }
    }

    /// Idempotent. After it returns no sample callback is running or will
    /// start, and the HAL objects are gone.
    func stop() {
        if let rateListener, aggregateID != kAudioObjectUnknown {
            var address = globalAddress(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(aggregateID, &address, listenerQueue, rateListener)
        }
        rateListener = nil
        if aggregateID != kAudioObjectUnknown, let procID {
            if started { AudioDeviceStop(aggregateID, procID) }
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        started = false
        // IOBlocks are dispatched synchronously, so after AudioDeviceStop no
        // new one begins; this waits out one that was already running.
        ioQueue.sync {}
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func createTap() throws {
        let description: CATapDescription
        if !narrowToBundleIDs.isEmpty, #available(macOS 26.0, *) {
            // Only the call apps: no notification sounds, music or Siri.
            // processRestoreEnabled keeps the tap attached when an app
            // relaunches mid-call.
            description = CATapDescription(monoMixdownOfProcesses: [])
            description.bundleIDs = narrowToBundleIDs
            description.isProcessRestoreEnabled = true
            narrowed = true
        } else {
            // Everything except this process (which plays nothing).
            var excluded: [AudioObjectID] = []
            if let own = AudioHAL.processObject(for: getpid()) { excluded.append(own) }
            description = CATapDescription(monoGlobalTapButExcludeProcesses: excluded)
        }
        description.name = "MacCap call audio"
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.unmuted
        var created = AudioObjectID(kAudioObjectUnknown)
        try checkStatus(AudioHardwareCreateProcessTap(description, &created), "create_tap")
        tapID = created
    }

    private func readFormat() throws {
        var address = globalAddress(kAudioTapPropertyFormat)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var asbd = AudioStreamBasicDescription()
        try checkStatus(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd), "read_format")
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              asbd.mBitsPerChannel == 32,
              (1...64).contains(asbd.mChannelsPerFrame),
              (8_000...384_000).contains(asbd.mSampleRate) else {
            throw SystemTapFailure(stage: "unsupported_format", status: OSStatus(bitPattern: asbd.mFormatID))
        }
        format = asbd
    }

    private func createAggregate() throws {
        var uidAddress = globalAddress(kAudioTapPropertyUID)
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        var tapUID: Unmanaged<CFString>?
        try checkStatus(AudioObjectGetPropertyData(tapID, &uidAddress, 0, nil, &uidSize, &tapUID), "read_tap_uid")
        guard let tapUID = tapUID?.takeRetainedValue() else {
            throw SystemTapFailure(stage: "read_tap_uid", status: -1)
        }
        // Tap-only and private: no hardware subdevice is opened, so starting
        // it cannot add another device's input streams or change a Bluetooth
        // headset's profile mid-call. No tap auto-start: it makes
        // AudioDeviceStart wait for the first tapped audio, which on a quiet
        // call may be minutes away.
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MacCap call audio",
            kAudioAggregateDeviceUIDKey: "maccap.call-audio.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [] as [Any],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID as String,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var created = AudioObjectID(kAudioObjectUnknown)
        try checkStatus(AudioHardwareCreateAggregateDevice(description as CFDictionary, &created),
                        "create_aggregate")
        aggregateID = created
    }

    private func seedAndWatchSampleRate() {
        let seeded = AudioHAL.nominalRate(aggregateID)
        sampleRate.withLock { $0 = seeded > 0 ? seeded : format.mSampleRate }
        let aggregate = aggregateID
        let box = sampleRate
        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            let rate = AudioHAL.nominalRate(aggregate)
            if rate > 0 {
                box.withLock { $0 = rate }
                Log.shared.write("system tap: nominal sample rate changed to \(Int(rate)) Hz")
            }
        }
        var address = globalAddress(kAudioDevicePropertyNominalSampleRate)
        if AudioObjectAddPropertyListenerBlock(aggregateID, &address, listenerQueue, listener) == noErr {
            rateListener = listener
        }
    }

    private func startIO() throws {
        let channels = Int(format.mChannelsPerFrame)
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let handler = onSamples
        let box = sampleRate
        var created: AudioDeviceIOProcID?
        try checkStatus(AudioDeviceCreateIOProcIDWithBlock(&created, aggregateID, ioQueue) {
            _, inputData, inputTime, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard let first = buffers.first, first.mDataByteSize > 0 else { return }
            let floatSize = MemoryLayout<Float>.size
            var mono: [Float]
            if interleaved {
                guard let data = first.mData else { return }
                let frames = Int(first.mDataByteSize) / (floatSize * channels)
                guard frames > 0 else { return }
                let samples = data.assumingMemoryBound(to: Float.self)
                mono = [Float](repeating: 0, count: frames)
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<channels { sum += samples[frame * channels + channel] }
                    mono[frame] = sum / Float(channels)
                }
            } else {
                let frames = Int(first.mDataByteSize) / floatSize
                guard frames > 0 else { return }
                mono = [Float](repeating: 0, count: frames)
                var used = 0
                for buffer in buffers {
                    guard let data = buffer.mData, Int(buffer.mDataByteSize) / floatSize >= frames else { continue }
                    let samples = data.assumingMemoryBound(to: Float.self)
                    for frame in 0..<frames { mono[frame] += samples[frame] }
                    used += 1
                }
                guard used > 0 else { return }
                if used > 1 { for frame in 0..<frames { mono[frame] /= Float(used) } }
            }
            let hasHostTime = inputTime.pointee.mFlags.contains(.hostTimeValid)
            let start = hasHostTime ? hostSeconds(inputTime.pointee.mHostTime) : hostSeconds()
            handler(mono, box.withLock { $0 }, start)
        }, "create_io_proc")
        procID = created
        // The first start raises the System Audio Recording prompt. A refusal
        // still returns noErr and then delivers exact zeros, which is why the
        // recorder checks levels rather than trusting this status.
        try checkStatus(AudioDeviceStart(aggregateID, created), "start_io")
        started = true
    }
}
