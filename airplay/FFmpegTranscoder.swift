import Foundation

struct PlaybackSession: Sendable {
    let playbackURL: URL
    let cleanup: @Sendable () -> Void
}

enum FFmpegTranscoder {
    private static let alwaysRemuxExtensions: Set<String> = [
        "mkv", "avi", "webm", "wmv", "flv", "ts", "m2ts",
        "mp4", "mov", "m4v"
    ]
    private static let airPlayAudio: Set<String> = ["aac", "ac3", "eac3", "mp3"]

    static func needsRemux(for url: URL) -> Bool {
        alwaysRemuxExtensions.contains(url.pathExtension.lowercased())
    }

    static func preparePlaybackSession(
        for source: URL,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> PlaybackSession {
        progress?(L10n.string("status_starting"))

        // Direct play only for types we never remux (shouldn't reach here for normal picks).
        if !needsRemux(for: source) {
            return PlaybackSession(playbackURL: source, cleanup: {})
        }

        // Previous runs left 20–90 GB of orphan remuxes and caused "could not prepare".
        purgeOrphanedTemps()

        let sourceSize = max((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0, 1)
        try ensureFreeSpace(needed: sourceSize)

        let ffmpeg = try resolveFFmpegURL()
        // Child ffmpeg does NOT inherit security-scoped bookmarks. Stage into the container.
        let accessible = try stageInputForFFmpeg(from: source)

        let probe: StreamProbe
        do {
            probe = try await probeStreams(ffmpeg: ffmpeg, source: accessible.url)
        } catch {
            accessible.cleanup()
            throw error
        }

        guard probe.videoCodec != nil else {
            accessible.cleanup()
            let msg = "FFmpeg could not read the video (sandbox). Try Choose File again."
            print("[MikaCast] probe failed — no video codec for \(accessible.url.path)")
            throw TranscoderError.remuxFailed(msg)
        }

        print("[MikaCast] probe ok video=\(probe.videoCodec ?? "?") audio=\(probe.audioCodec ?? "?")")
        return try await startFullCompatibilityRemux(
            source: source,
            accessibleInput: accessible,
            probe: probe,
            progress: progress
        )
    }

    /// Deletes leftover mikacast-/airplay- remux files from the container tmp.
    static func purgeOrphanedTemps() {
        let tmp = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tmp,
            includingPropertiesForKeys: nil
        ) else { return }

        for url in files {
            let name = url.lastPathComponent
            if name.hasPrefix("mikacast-") || name.hasPrefix("airplay-") {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func ensureFreeSpace(needed: Int) throws {
        let tmp = FileManager.default.temporaryDirectory
        let values = try tmp.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = Int(values.volumeAvailableCapacityForImportantUsage ?? 0)
        // Need room for staged clone (often 0 with APFS) + full remux output.
        let required = needed + (needed / 10) + 500_000_000
        if available > 0, available < required {
            let needGB = String(format: "%.0f", Double(required) / 1_000_000_000)
            let haveGB = String(format: "%.0f", Double(available) / 1_000_000_000)
            let msg = "Not enough free disk space (need ~\(needGB) GB, have \(haveGB) GB)."
            print("[MikaCast] \(msg)")
            throw TranscoderError.remuxFailed(msg)
        }
    }

    private static func startFullCompatibilityRemux(
        source: URL,
        accessibleInput: (url: URL, cleanup: @Sendable () -> Void),
        probe: StreamProbe,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> PlaybackSession {
        let ffmpeg = try resolveFFmpegURL()
        let workID = UUID().uuidString
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("mikacast-\(workID).mp4.part")
        let finalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mikacast-\(workID).mp4")
        let progressURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mikacast-\(workID).progress")
        let errURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mikacast-\(workID).err")

        let sourceSize = max((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0, 1)
        progress?("\(L10n.string("status_preparing")) 0%")

        let canCopyAudio = probe.audioCodec.map { airPlayAudio.contains($0) } ?? false
        let isHEVC = probe.videoCodec == "hevc" || probe.videoCodec == "h265"

        var arguments: [String] = [
            "-y", "-nostdin",
            "-loglevel", "error",
            "-i", accessibleInput.url.path,
            "-sn", "-dn",
            "-map", "0:v:0",
            "-map", "0:a:0?",
            "-c:v", "copy"
        ]
        if isHEVC {
            arguments += ["-tag:v", "hvc1"]
        }
        if canCopyAudio {
            arguments += ["-c:a", "copy"]
        } else {
            arguments += ["-c:a", "aac", "-b:a", "192k", "-ac", "2"]
        }
        // `.part` is not a known muxer extension — force mp4.
        arguments += ["-f", "mp4", "-progress", progressURL.path, "-nostats", output.path]

        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let errHandle = try FileHandle(forWritingTo: errURL)

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = arguments
        process.standardError = errHandle
        process.standardOutput = FileHandle.nullDevice

        try process.run()
        try? errHandle.close()

        let ok = await waitForProcessExit(
            process,
            output: output,
            sourceSize: sourceSize,
            progressURL: progressURL,
            progress: progress,
            timeout: 60 * 60
        )
        try? FileManager.default.removeItem(at: progressURL)

        if !ok || process.terminationStatus != 0 {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            let errText = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
            print("[MikaCast] ffmpeg remux failed status=\(process.terminationStatus) ok=\(ok)")
            print("[MikaCast] ffmpeg stderr:\n\(errText)")
            try? FileManager.default.removeItem(at: errURL)
            accessibleInput.cleanup()
            try? FileManager.default.removeItem(at: output)
            if process.terminationStatus != 0 {
                throw TranscoderError.remuxFailed(
                    errText.isEmpty ? "FFmpeg failed (\(process.terminationStatus))" : errText
                )
            }
            throw TranscoderError.streamTimeout
        }

        try? FileManager.default.removeItem(at: errURL)
        try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.moveItem(at: output, to: finalURL)

        // Sanity: remuxed file must be a meaningful fraction of the source.
        let outSize = fileSize(finalURL)
        print("[MikaCast] remux done out=\(outSize) source=\(sourceSize) path=\(finalURL.lastPathComponent)")
        if sourceSize > 50_000_000, outSize < sourceSize / 20 {
            accessibleInput.cleanup()
            try? FileManager.default.removeItem(at: finalURL)
            let msg = "Remux output too small (\(outSize) bytes) — preparation incomplete."
            print("[MikaCast] \(msg)")
            throw TranscoderError.remuxFailed(msg)
        }

        let cleanup: @Sendable () -> Void = {
            accessibleInput.cleanup()
            try? FileManager.default.removeItem(at: finalURL)
        }

        return PlaybackSession(playbackURL: finalURL, cleanup: cleanup)
    }

    /// Puts a container-local path in front of ffmpeg (hard link or APFS clone).
    private static func stageInputForFFmpeg(
        from source: URL
    ) throws -> (url: URL, cleanup: @Sendable () -> Void) {
        let fm = FileManager.default
        let staged = fm.temporaryDirectory
            .appendingPathComponent("mikacast-in-\(UUID().uuidString).\(source.pathExtension)")

        try? fm.removeItem(at: staged)

        do {
            try fm.linkItem(at: source, to: staged)
        } catch {
            // APFS clone-copy is usually instant even for 20+ GB.
            do {
                try fm.copyItem(at: source, to: staged)
            } catch {
                print("[MikaCast] stageInput failed: \(error)")
                throw TranscoderError.remuxFailed(
                    "Could not stage file for FFmpeg: \(error.localizedDescription)"
                )
            }
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
        proc.arguments = ["nohidden", staged.path, source.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()

        return (staged, { try? FileManager.default.removeItem(at: staged) })
    }

    private static func waitForProcessExit(
        _ process: Process,
        output: URL,
        sourceSize: Int,
        progressURL: URL,
        progress: (@Sendable (String) -> Void)?,
        timeout: TimeInterval
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var lastSize = -1
        var stuckTicks = 0

        while Date() < deadline {
            let size = fileSize(output)
            reportProgress(
                outputSize: size,
                sourceSize: sourceSize,
                progressURL: progressURL,
                progress: progress
            )

            if !process.isRunning {
                return true
            }

            if size == lastSize {
                stuckTicks += 1
            } else {
                stuckTicks = 0
                lastSize = size
            }
            if stuckTicks > 480, size > 0 {
                process.terminate()
                return false
            }

            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return !process.isRunning
    }

    private static func reportProgress(
        outputSize: Int,
        sourceSize: Int,
        progressURL: URL,
        progress: (@Sendable (String) -> Void)?
    ) {
        guard let progress else { return }

        let pct = min(99, max(0, (outputSize * 100) / max(sourceSize, 1)))
        var label = "\(L10n.string("status_preparing")) \(pct)%"

        if let text = try? String(contentsOf: progressURL, encoding: .utf8),
           let match = text.matches(of: /out_time=(\d{2}:\d{2}:\d{2})/).last {
            label = "\(L10n.string("status_preparing")) \(pct)% · \(match.1)"
        }

        progress(label)
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private struct StreamProbe: Sendable {
        var videoCodec: String?
        var audioCodec: String?
    }

    private static func probeStreams(ffmpeg: URL, source: URL) async throws -> StreamProbe {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = ffmpeg
            process.arguments = ["-hide_banner", "-i", source.path]
            let stderr = Pipe()
            process.standardError = stderr
            process.standardOutput = Pipe()

            process.terminationHandler = { _ in
                let data = stderr.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                var probe = StreamProbe()
                if let match = text.firstMatch(of: /Video:\s*([a-zA-Z0-9_]+)/) {
                    probe.videoCodec = String(match.1).lowercased()
                }
                if let match = text.firstMatch(of: /Audio:\s*([a-zA-Z0-9_]+)/) {
                    probe.audioCodec = String(match.1).lowercased()
                }
                continuation.resume(returning: probe)
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func resolveFFmpegURL() throws -> URL {
        let candidates = [
            Bundle.main.url(forResource: "ffmpeg", withExtension: nil),
            Bundle.main.url(forResource: "ffmpeg", withExtension: nil, subdirectory: "Resources"),
            URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
        ].compactMap { $0 }

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }

        if let bundled = Bundle.main.url(forResource: "ffmpeg", withExtension: nil)
            ?? Bundle.main.url(forResource: "ffmpeg", withExtension: nil, subdirectory: "Resources") {
            let tempFFmpeg = FileManager.default.temporaryDirectory.appendingPathComponent("airplay-ffmpeg")
            if !FileManager.default.fileExists(atPath: tempFFmpeg.path) {
                try FileManager.default.copyItem(at: bundled, to: tempFFmpeg)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempFFmpeg.path)
            }
            return tempFFmpeg
        }

        throw TranscoderError.ffmpegMissing
    }
}

enum TranscoderError: LocalizedError {
    case ffmpegMissing
    case remuxFailed(String)
    case streamTimeout

    var errorDescription: String? {
        let text: String
        switch self {
        case .ffmpegMissing:
            text = L10n.string("error_ffmpeg_missing")
        case .remuxFailed(let details):
            let tail = details.split(separator: "\n").suffix(3).joined(separator: "\n")
            text = L10n.string("error_remux_failed", tail)
        case .streamTimeout:
            text = L10n.string("error_stream_timeout")
        }
        print("[MikaCast] TranscoderError: \(self) → \(text)")
        return text
    }
}
