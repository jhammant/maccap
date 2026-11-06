import Foundation

struct FinalizeError: Error, CustomStringConvertible {
    let description: String
    /// The session holds no audio at all (capture never got going), so there
    /// is nothing to recover and it is not retried at every launch.
    var noAudio = false
}

/// Turns a session's raw ADTS segments into one stereo m4a (L = microphone,
/// R = system audio) plus a `.maccap.json` sidecar. The raw segments stay.
enum Finalizer {
    static let version = "0.1.0"
    /// Leading frames each AAC segment carries before its first real sample
    /// (encoder delay as ffmpeg decodes Apple's ADTS output). Measured by
    /// `MacCap selftest`, which fails if alignment drifts.
    static var primingFrames = 2112

    struct SegmentFile {
        let url: URL
        let frames: Int
    }

    @discardableResult
    static func finalize(sessionDir dir: URL, paths: MacCapPaths, config: MacCapConfig,
                         recovered: Bool = false) throws -> URL {
        var manifest = try SessionManifest.load(dir)
        if manifest.state == "finalized", let final = manifest.finalFile,
           FileManager.default.fileExists(atPath: final) {
            return URL(fileURLWithPath: final)
        }
        do {
            let url = try build(dir: dir, manifest: &manifest, paths: paths, config: config, recovered: recovered)
            manifest.state = "finalized"
            manifest.finalFile = url.path
            manifest.finalizeError = nil
            manifest.save(dir)
            return url
        } catch {
            manifest.state = (error as? FinalizeError)?.noAudio == true ? "empty" : "failed"
            manifest.finalizeError = "\(error)"
            manifest.save(dir)
            throw error
        }
    }

    private static func build(dir: URL, manifest: inout SessionManifest, paths: MacCapPaths,
                              config: MacCapConfig, recovered: Bool) throws -> URL {
        guard let ffmpeg = config.resolveFFmpeg(), let ffprobe = config.resolveFFmpeg(tool: "ffprobe") else {
            throw FinalizeError(description: "ffmpeg/ffprobe not found (brew install ffmpeg, or set ffmpeg_path)")
        }
        if recovered || manifest.state == "recording" {
            manifest.recovered = true
            if manifest.endedAt == nil { manifest.endedAt = modifiedDate(dir) }
        }
        let mic = segments(stem: "mic", listed: manifest.micSegments, total: manifest.micStats?.writtenSeconds,
                           dir: dir, ffprobe: ffprobe)
        let system = segments(stem: "system", listed: manifest.systemSegments,
                              total: manifest.systemStats?.writtenSeconds, dir: dir, ffprobe: ffprobe)
        let micFrames = mic.reduce(0) { $0 + $1.frames }
        let systemFrames = system.reduce(0) { $0 + $1.frames }
        let total = max(micFrames, systemFrames)
        guard total > 0 else { throw FinalizeError(description: "no audio in \(dir.lastPathComponent)", noAudio: true) }
        let rate = Int(StemWriter.outputRate)
        let duration = Double(total) / Double(rate)

        var args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y"]
        var filters: [String] = []
        var inputIndex = 0
        func addStem(_ files: [SegmentFile], label: String) {
            if files.isEmpty {
                args += ["-f", "lavfi", "-t", String(format: "%.6f", duration), "-i", "anullsrc=r=\(rate):cl=mono"]
                filters.append("[\(inputIndex):a]aformat=sample_fmts=fltp:sample_rates=\(rate):channel_layouts=mono,"
                    + "apad=whole_len=\(total),atrim=end_sample=\(total)[\(label)]")
                inputIndex += 1
                return
            }
            var parts: [String] = []
            for file in files {
                args += ["-i", file.url.path]
                let part = "\(label)\(parts.count)"
                filters.append("[\(inputIndex):a]aresample=\(rate),aformat=sample_fmts=fltp:channel_layouts=mono,"
                    + "atrim=start_sample=\(primingFrames):end_sample=\(primingFrames + file.frames),"
                    + "asetpts=N/SR/TB[\(part)]")
                parts.append("[\(part)]")
                inputIndex += 1
            }
            let joined = parts.count == 1 ? parts[0] : "\(parts.joined())concat=n=\(parts.count):v=0:a=1"
            filters.append("\(parts.count == 1 ? parts[0] + "anull," : joined + ",")"
                + "apad=whole_len=\(total),atrim=end_sample=\(total)[\(label)]")
        }
        addStem(mic, label: "L")
        addStem(system, label: "R")
        filters.append("[L][R]join=inputs=2:channel_layout=stereo:map=0.0-FL|1.0-FR[out]")

        let base = "\(manifest.stamp)-\(manifest.id)"
        let outDir = manifest.skipped ? paths.audio.appendingPathComponent("skipped", isDirectory: true) : paths.audio
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let final = outDir.appendingPathComponent("\(base).m4a")
        let sidecar = outDir.appendingPathComponent("\(base).maccap.json")
        if FileManager.default.fileExists(atPath: final.path) {
            Log.shared.write("finalize: \(final.lastPathComponent) already exists; leaving it")
            return final
        }
        let temp = outDir.appendingPathComponent(".\(base).m4a.part")
        args += ["-filter_complex", filters.joined(separator: ";"), "-map", "[out]",
                 "-c:a", "aac", "-b:a", "128k", "-ar", "\(rate)", "-movflags", "+faststart", "-f", "mp4", temp.path]
        let result = run(ffmpeg, args)
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw FinalizeError(description: "ffmpeg failed (\(result.status)): \(result.output.suffix(800))")
        }
        let probe = run(ffprobe, ["-v", "error", "-show_entries", "stream=channels:format=duration",
                                  "-of", "default=noprint_wrappers=1", temp.path]).output
        let channels = value(probe, "channels").flatMap(Int.init) ?? 0
        let probed = value(probe, "duration").flatMap(Double.init) ?? 0
        guard channels == 2, abs(probed - duration) < 1.0 else {
            throw FinalizeError(description: "output check failed: \(channels) ch, \(probed) s, expected \(duration) s; "
                + "kept \(temp.path)")
        }
        // Live notes taken during the call sit next to the recording.
        var notesName: String?
        let liveNotes = dir.appendingPathComponent(LiveNotesFiles.sessionFile)
        if FileManager.default.fileExists(atPath: liveNotes.path) {
            let notesOut = outDir.appendingPathComponent("\(base).notes.md")
            if !FileManager.default.fileExists(atPath: notesOut.path) {
                try? FileManager.default.copyItem(at: liveNotes, to: notesOut)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: notesOut.path)
            }
            if FileManager.default.fileExists(atPath: notesOut.path) { notesName = notesOut.lastPathComponent }
        }
        let sidecarData = try sidecarJSON(manifest: manifest, fileName: final.lastPathComponent, duration: duration,
                                          micFrames: micFrames, systemFrames: systemFrames,
                                          micFiles: mic, systemFiles: system, liveNotes: notesName)
        try sidecarData.write(to: sidecar, options: .atomic)
        try FileManager.default.moveItem(at: temp, to: final)
        Log.shared.write("finalize: wrote \(final.path) (\(String(format: "%.1f", duration)) s)")
        return final
    }

    /// The segments listed in the manifest, plus any on disk it missed (a
    /// crash between creating a file and saving the manifest), in order.
    /// A segment's length comes from the timeline (where the next one starts,
    /// or the stem's total), because AAC pads the last packet of every file;
    /// the packet count is only the fallback after a crash.
    static func segments(stem: String, listed: [SegmentRecord], total: Double?, dir: URL,
                         ffprobe: String) -> [SegmentFile] {
        var starts: [String: Double] = [:]
        for segment in listed { starts[segment.file] = segment.startSeconds }
        var names = listed.map(\.file)
        let onDisk = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("\(stem)-") && $0.hasSuffix(".aac") }
        for name in onDisk where !names.contains(name) { names.append(name) }
        names.sort()
        let rate = StemWriter.outputRate
        return names.enumerated().compactMap { index, name in
            let url = dir.appendingPathComponent(name)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
                  size > 0 else { return nil }
            let output = run(ffprobe, ["-v", "error", "-select_streams", "a:0", "-count_packets",
                                       "-show_entries", "stream=nb_read_packets", "-of", "csv=p=0", url.path]).output
            guard let packets = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)), packets > 0 else {
                Log.shared.write("finalize: skipping unreadable segment \(name)")
                return nil
            }
            let available = max(0, packets * 1024 - primingFrames)
            var frames = available
            if let start = starts[name] {
                let next = index + 1 < names.count ? starts[names[index + 1]] : total
                if let next, next >= start { frames = min(available, Int(((next - start) * rate).rounded())) }
            }
            return frames > 0 ? SegmentFile(url: url, frames: frames) : nil
        }
    }

    private static func sidecarJSON(manifest: SessionManifest, fileName: String, duration: Double,
                                    micFrames: Int, systemFrames: Int,
                                    micFiles: [SegmentFile], systemFiles: [SegmentFile],
                                    liveNotes: String? = nil) throws -> Data {
        func health(_ stats: StemStats?, frames: Int) -> [String: Any] {
            var out: [String: Any] = ["seconds": Double(frames) / StemWriter.outputRate]
            guard let stats else {
                out["status"] = frames > 0 ? "unknown" : "missing"
                return out
            }
            out["status"] = frames == 0 ? "missing" : (stats.heardAudio ? "ok" : "silent")
            out["audible_seconds"] = round(stats.audibleSeconds * 10) / 10
            out["speech_seconds"] = round(stats.speechSeconds * 10) / 10
            out["peak_level"] = stats.peakLevel
            if let rms = stats.rmsDBFS { out["rms_dbfs"] = round(rms * 10) / 10 }
            out["non_zero_buffers"] = stats.nonZeroBuffers
            out["buffers"] = stats.buffers
            out["sample_rates"] = stats.sampleRates
            return out
        }
        func offsets(_ stats: StemStats?) -> [String: Any] {
            guard let stats else { return [:] }
            var out: [String: Any] = ["padded_seconds": round(stats.paddedSeconds * 1000) / 1000,
                                      "dropped_seconds": round(stats.droppedSeconds * 1000) / 1000]
            if let first = stats.firstBufferOffset { out["first_buffer_seconds"] = round(first * 1000) / 1000 }
            return out
        }
        let micHealth = health(manifest.micStats, frames: micFrames)
        let systemHealth = health(manifest.systemStats, frames: systemFrames)
        let micOK = micHealth["status"] as? String == "ok"
        let systemOK = systemHealth["status"] as? String == "ok"
        let verdict = micOK && systemOK ? "both_sides" : micOK ? "mic_only" : systemOK ? "system_only" : "check"
        let apps: [[String: Any]] = manifest.apps.map { ["bundle_id": $0.bundleID ?? NSNull(), "name": $0.name] }
        let channels: [String: Any] = [
            "left": ["source": "microphone", "speaker": "local"],
            "right": ["source": "system_audio", "speaker": "remote"],
        ]
        let offsetInfo: [String: Any] = [
            "timeline": "host time from session start; gaps padded with silence",
            "mic": offsets(manifest.micStats),
            "system": offsets(manifest.systemStats),
            "priming_frames_trimmed": primingFrames,
        ]
        let alerts: [[String: Any]] = manifest.alerts.map { ["at": round($0.at), "kind": $0.kind] }
        let healthInfo: [String: Any] = [
            "verdict": verdict, "mic": micHealth, "system": systemHealth,
            "mic_permission": manifest.micPermission ?? "unknown",
            "remote_silence_alerts": alerts, "notes": manifest.notes,
        ]
        let routes: [[String: Any]] = manifest.routes.map {
            ["at": round($0.at * 10) / 10, "stem": $0.stem, "route": $0.route]
        }
        let segmentNames: [String: Any] = [
            "mic": micFiles.map { $0.url.lastPathComponent },
            "system": systemFiles.map { $0.url.lastPathComponent },
        ]
        let rawDir = "sessions/\(manifest.stamp.replacingOccurrences(of: " ", with: "-"))-\(manifest.id)"
        let route: [String: Any] = [
            "system_tap": manifest.tapMode, "tap_rebuilds": manifest.tapRebuilds,
            "routes": routes, "segments": segmentNames, "raw_dir": rawDir,
        ]
        var object: [String: Any] = [
            "maccap_version": version,
            "file": fileName,
            "session_id": manifest.id,
            "duration_seconds": round(duration * 1000) / 1000,
            "trigger": manifest.trigger,
            "skipped": manifest.skipped,
            "recovered_after_crash": manifest.recovered,
        ]
        object["started_at"] = manifest.startedAt
        object["ended_at"] = manifest.endedAt ?? NSNull()
        object["apps"] = apps
        object["channels"] = channels
        object["offsets"] = offsetInfo
        object["health"] = healthInfo
        object["capture_route"] = route
        if let liveNotes { object["live_notes"] = liveNotes }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: Setting a recording aside

    /// Moves a saved recording, its sidecar and its notes into `skipped/`
    /// (nothing is deleted; pipelines that watch the main folder never see it) and notes why
    /// in the sidecar. Returns the recording's new place.
    @discardableResult
    static func setAside(_ recording: URL, reason: String, paths: MacCapPaths) throws -> URL {
        let folder = paths.audio.appendingPathComponent("skipped", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let base = recording.deletingPathExtension()
        let sidecar = base.appendingPathExtension("maccap.json")
        if var json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: sidecar))) as? [String: Any] {
            json["skipped"] = true
            json["set_aside"] = reason
            if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                try data.write(to: sidecar, options: .atomic)
            }
        }
        var moved = recording
        for file in [recording, sidecar, base.appendingPathExtension("notes.md")]
        where FileManager.default.fileExists(atPath: file.path) {
            let target = folder.appendingPathComponent(file.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            try FileManager.default.moveItem(at: file, to: target)
            if file == recording { moved = target }
        }
        Log.shared.write("set aside \(recording.lastPathComponent): \(reason)")
        return moved
    }

    // MARK: Recovery

    /// Sessions that need finalizing: stopped but not finalized, failed, or
    /// still marked recording by a process that is gone. "empty" sessions
    /// (no audio was captured) are left alone; their folders are kept.
    static func pending(paths: MacCapPaths, excluding active: URL? = nil) -> [URL] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: paths.sessions, includingPropertiesForKeys: nil))
            ?? []
        return dirs.filter { dir in
            guard dir.standardizedFileURL != active?.standardizedFileURL,
                  let manifest = try? SessionManifest.load(dir) else { return false }
            switch manifest.state {
            case "stopped", "failed": return true
            case "recording":
                if manifest.pid == getpid() { return false }
                return !isLiveMacCap(manifest.pid)
            default: return false
            }
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func recoverPending(paths: MacCapPaths, config: MacCapConfig, excluding active: URL? = nil)
        -> [(dir: URL, result: Result<URL, Error>)] {
        pending(paths: paths, excluding: active).map { dir in
            let crashed = (try? SessionManifest.load(dir))?.state == "recording"
            do {
                let url = try finalize(sessionDir: dir, paths: paths, config: config, recovered: crashed)
                return (dir, .success(url))
            } catch {
                Log.shared.write("recover: \(dir.lastPathComponent) failed: \(error)")
                return (dir, .failure(error))
            }
        }
    }

    private static func isLiveMacCap(_ pid: Int32) -> Bool {
        guard isProcessAlive(pid) else { return false }
        return AudioProcess.processName(pid).lowercased().contains("maccap")
    }

    // MARK: Helpers

    private static func modifiedDate(_ dir: URL) -> String {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys:
            [.contentModificationDateKey])) ?? []
        let latest = files.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate }.max() ?? Date()
        return Clock.iso(latest)
    }

    private static func value(_ text: String, _ key: String) -> String? {
        text.split(separator: "\n").first { $0.hasPrefix("\(key)=") }.map { String($0.dropFirst(key.count + 1)) }
    }

    static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "\(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
