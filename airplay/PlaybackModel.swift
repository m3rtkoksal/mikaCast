import AVFoundation
import Combine
import Foundation

@MainActor
@Observable
final class PlaybackModel {
    private(set) var player = AVPlayer()
    private(set) var currentFileName: String?
    private(set) var isPreparing = false
    private(set) var statusMessage = L10n.string("status_idle")
    private(set) var isExternalPlaybackActive = false

    private var statusKey = "status_idle"
    private var statusFormatArg: String?
    private var sessionCleanup: (@Sendable () -> Void)?
    private var sourceURL: URL?
    private var securityScopedURL: URL?
    private var cancellables = Set<AnyCancellable>()
    private var itemObservers = [NSObjectProtocol]()
    private var stallCheckTimer: Timer?
    private var lastPlaybackTime: CMTime = .zero
    private var stallRecoveryCount = 0

    init() {
        player.allowsExternalPlayback = true
        player.automaticallyWaitsToMinimizeStalling = true
        player.actionAtItemEnd = .pause

        player.publisher(for: \.isExternalPlaybackActive)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                self?.isExternalPlaybackActive = active
            }
            .store(in: &cancellables)

        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                if status == .playing {
                    self?.startStallMonitor()
                }
            }
            .store(in: &cancellables)
    }

    func refreshLanguage() {
        applyStatus(key: statusKey, arg: statusFormatArg)
    }

    private func applyStatus(key: String, arg: String? = nil) {
        statusKey = key
        statusFormatArg = arg
        if let arg {
            statusMessage = "\(L10n.string(key)) \(arg)"
        } else {
            statusMessage = L10n.string(key)
        }
    }

    func play(file url: URL) async {
        stop(clearStatus: false)
        sourceURL = url
        currentFileName = url.lastPathComponent
        isPreparing = true
        applyStatus(key: "status_starting")
        stallRecoveryCount = 0

        if url.startAccessingSecurityScopedResource() {
            securityScopedURL = url
        }

        do {
            let progressHandler: @Sendable (String) -> Void = { [weak self] message in
                Task { @MainActor in
                    // Progress comes as "Preparing… 00:01:23" — keep raw while preparing.
                    self?.statusKey = "status_preparing"
                    self?.statusFormatArg = message
                    self?.statusMessage = message
                }
            }

            let session = try await Task.detached(priority: .userInitiated) {
                try await FFmpegTranscoder.preparePlaybackSession(for: url, progress: progressHandler)
            }.value

            sessionCleanup = session.cleanup

            applyStatus(key: "status_playing")

            let asset = AVURLAsset(url: session.playbackURL)
            // isPlayable can be false for some remuxed HEVC files even when they play fine.
            // Prefer checking tracks; only fail if there is no video track at all.
            let tracks = try await asset.load(.tracks)
            let hasVideo = tracks.contains { $0.mediaType == .video }
            guard hasVideo else {
                throw PlaybackError.notPlayable
            }

            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 8
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = true

            clearItemObservers()
            observePlayerItem(item)

            player.replaceCurrentItem(with: item)
            player.play()
        } catch {
            statusKey = "error"
            statusFormatArg = nil
            statusMessage = error.localizedDescription
            currentFileName = nil
            sourceURL = nil
            endSecurityScopedAccess()
            sessionCleanup?()
            sessionCleanup = nil
        }

        isPreparing = false
    }

    func stop(clearStatus: Bool = true) {
        stopStallMonitor()
        clearItemObservers()
        player.pause()
        player.replaceCurrentItem(with: nil)
        sessionCleanup?()
        sessionCleanup = nil
        endSecurityScopedAccess()
        currentFileName = nil
        sourceURL = nil
        stallRecoveryCount = 0
        if clearStatus {
            applyStatus(key: "status_idle")
        }
    }

    private func endSecurityScopedAccess() {
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
    }

    private func observePlayerItem(_ item: AVPlayerItem) {
        let center = NotificationCenter.default

        itemObservers.append(
            center.addObserver(
                forName: .AVPlayerItemPlaybackStalled,
                object: item,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.handlePlaybackStall(key: "status_stalled")
                }
            }
        )

        itemObservers.append(
            center.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor in
                    if let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                        self?.statusKey = "error"
                        self?.statusFormatArg = nil
                        self?.statusMessage = error.localizedDescription
                        self?.recoverAndPlay()
                    } else {
                        self?.handlePlaybackStall(key: "status_playback_error")
                    }
                }
            }
        )

        itemObservers.append(
            center.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.applyStatus(key: "status_finished")
                }
            }
        )
    }

    private func handlePlaybackStall(key: String) {
        guard stallRecoveryCount < 3 else {
            applyStatus(key: "status_stuck")
            return
        }

        stallRecoveryCount += 1
        applyStatus(key: key)
        recoverAndPlay()
    }

    private func recoverAndPlay() {
        let current = player.currentTime()
        player.pause()
        player.seek(
            to: CMTimeAdd(current, CMTime(seconds: 0.25, preferredTimescale: 600)),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            self?.player.play()
            self?.applyStatus(key: "status_playing")
        }
    }

    private func startStallMonitor() {
        stopStallMonitor()
        lastPlaybackTime = player.currentTime()

        stallCheckTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkForFrozenPlayback()
            }
        }
    }

    private func checkForFrozenPlayback() {
        guard player.timeControlStatus == .playing || player.timeControlStatus == .waitingToPlayAtSpecifiedRate else {
            return
        }

        let current = player.currentTime()
        let advanced = CMTimeCompare(current, lastPlaybackTime) > 0

        if !advanced, CMTimeGetSeconds(current) > 1 {
            handlePlaybackStall(key: "status_frozen")
        }

        lastPlaybackTime = current
    }

    private func stopStallMonitor() {
        stallCheckTimer?.invalidate()
        stallCheckTimer = nil
    }

    private func clearItemObservers() {
        for observer in itemObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        itemObservers.removeAll()
    }
}

enum PlaybackError: LocalizedError {
    case notPlayable

    var errorDescription: String? {
        switch self {
        case .notPlayable:
            return L10n.string("error_not_playable")
        }
    }
}
