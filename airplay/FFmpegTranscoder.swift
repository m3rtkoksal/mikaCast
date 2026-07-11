import Foundation

struct PlaybackSession: Sendable {
    let playbackURL: URL
    let cleanup: @Sendable () -> Void
}

enum FFmpegTranscoder {
    private static let remuxExtensions: Set<String> = ["mkv", "avi", "webm", "wmv", "flv", "ts", "m2ts"]
    /// Codecs Apple TV / AirPlay can play without re-encoding audio.
    private static let airPlayAudio: Set<String> = ["aac", "ac3", "eac3", "mp3"]

    static func needsRemux(for url: URL) -> Bool {
        remuxExtensions.contains(url.pathExtension.lowercased())
    }

    /// AVPlayer cannot open MKV. Remux to a local MP4 file for AirPlay.
    static func preparePlaybackSession(
        for source: URL,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> PlaybackSession {
        if !needsRemux(for: source) {
            return PlaybackSession(playbackURL: source, cleanup: {})
        }
        return try await remuxToAirPlayMP4(source: source, progress: progress)
    }

    private static func remuxToAirPlayMP4(
        source: URL,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> PlaybackSession {
        let ffmpeg = try resolveFFmpegURL()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("airplay-\(UUID().uuidString).mp4")

        try? FileManager.default.removeItem(at: output)

        let probe = try await probeStreams(ffmpeg: ffmpeg, source: source)
        let canCopyAudio = probe.audioCodec.map { airPlayAudio.contains($0) } ?? false
        let isHEVC = probe.videoCodec == "hevc" || probe.videoCodec == "h265"

        progress?(L10n.string("status_starting"))

        // Local MP4 so AirPlay streams from this Mac (not localhost HLS).
        // HEVC must be tagged hvc1 — hev1 is rejected by AVPlayer / AirPlay.
        var arguments: [String] = [
            "-y", "-nostdin",
            "-i", source.path,
            "-sn",
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

        arguments += [
            "-fflags", "+genpts",
            "-avoid_negative_ts", "make_zero",
            "-movflags", "+faststart",
            output.path
        ]

        try await runFFmpeg(ffmpeg: ffmpeg, arguments: arguments, progress: progress)

        guard FileManager.default.fileExists(atPath: output.path) else {
            throw TranscoderError.remuxFailed("Output missing")
        }

        let cleanup: @Sendable () -> Void = {
            try? FileManager.default.removeItem(at: output)
        }

        return PlaybackSession(playbackURL: output, cleanup: cleanup)
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

    private static func runFFmpeg(
        ffmpeg: URL,
        arguments: [String],
        progress: (@Sendable (String) -> Void)?
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = ffmpeg
            process.arguments = arguments

            let stderr = Pipe()
            process.standardError = stderr
            process.standardOutput = Pipe()

            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
                if let progress, let time = line.firstMatch(of: /time=(\d{2}:\d{2}:\d{2})/)?.1 {
                    progress("\(L10n.string("status_preparing")) \(time)")
                }
            }

            process.terminationHandler = { process in
                stderr.fileHandleForReading.readabilityHandler = nil
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let data = stderr.fileHandleForReading.readDataToEndOfFile()
                    let message = String(data: data, encoding: .utf8) ?? "FFmpeg failed"
                    continuation.resume(throwing: TranscoderError.remuxFailed(message))
                }
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
        switch self {
        case .ffmpegMissing:
            return L10n.string("error_ffmpeg_missing")
        case .remuxFailed(let details):
            let tail = details.split(separator: "\n").suffix(3).joined(separator: "\n")
            return L10n.string("error_remux_failed", tail)
        case .streamTimeout:
            return L10n.string("error_stream_timeout")
        }
    }
}
