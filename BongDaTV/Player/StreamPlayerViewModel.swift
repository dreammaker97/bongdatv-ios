import AVFoundation
import Combine
import Foundation

struct PlaybackCandidate {
    let url: URL
    let headers: [String: String]?
    let label: String
    let isUsingServerProxy: Bool
    let commentator: CommentatorItem
}

@MainActor
final class StreamPlayerViewModel: ObservableObject {
    @Published var match: MatchGroup
    @Published var selectedCommentator: CommentatorItem
    @Published var player: AVPlayer?
    @Published var isLoading = true
    @Published var statusText = "Đang lấy luồng phát..."
    @Published var errorMessage: String?
    @Published var activeRouteLabel = ""
    @Published var isUsingServerProxy = false
    @Published var activeMode: PlaybackMode

    private let settings: AppSettings
    private let apiClient = BongDaAPIClient()

    private var playSessionID = 0
    private var candidates: [PlaybackCandidate] = []
    private var candidateIndex = 0
    private var hasStartedPlaying = false

    private var itemStatusObserver: NSKeyValueObservation?
    private var timeControlObserver: NSKeyValueObservation?
    private var failureObserver: NSObjectProtocol?
    private var watchdogTask: Task<Void, Never>?

    init(match: MatchGroup, commentator: CommentatorItem, settings: AppSettings) {
        self.match = match
        self.selectedCommentator = commentator
        self.settings = settings
        self.activeMode = settings.playbackMode
    }

    func start(commentator: CommentatorItem? = nil, modeOverride: PlaybackMode? = nil) {
        if let commentator = commentator {
            selectedCommentator = commentator
        }
        if let modeOverride = modeOverride {
            activeMode = modeOverride
        } else {
            activeMode = settings.playbackMode
        }

        playSessionID += 1
        let session = playSessionID
        cleanupObserversAndWatchdog()
        player?.pause()
        player = nil

        hasStartedPlaying = false
        isLoading = true
        errorMessage = nil
        statusText = "Đang kết nối luồng phát (\(selectedCommentator.blv))..."
        activeRouteLabel = activeMode.shortBadge
        isUsingServerProxy = (activeMode == .serverProxy)

        configureAudioSession()

        Task {
            await resolveAndBeginSession(session: session)
        }
    }

    func stop() {
        playSessionID += 1
        cleanupObserversAndWatchdog()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    private func configureAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay])
            try audioSession.setActive(true)
        } catch {
            // Non-fatal
        }
    }

    private func resolveAndBeginSession(session: Int) async {
        guard session == playSessionID else { return }

        var builtCandidates: [PlaybackCandidate] = []
        let primaryComm = selectedCommentator
        var commentatorsToTry: [CommentatorItem] = [primaryComm]
        for c in match.commentators where c.id != primaryComm.id {
            commentatorsToTry.append(c)
        }

        let baseURLs = settings.candidateBaseURLs
        let fallbackBase = baseURLs.first ?? AppSettings.defaultLANServerURL

        for (cIdx, comm) in commentatorsToTry.enumerated() {
            guard session == playSessionID else { return }
            var entries: [StreamEntry] = []
            var usedBase = fallbackBase

            if !comm.livestreamId.isEmpty {
                if let res = try? await apiClient.fetchStreams(baseURLs: baseURLs, livestreamID: comm.livestreamId) {
                    entries = res.entries
                    usedBase = res.usedBaseURL
                }
            }

            if entries.isEmpty, let cachedURL = comm.urlHls ?? comm.url {
                let isHLS = cachedURL.contains(".m3u8")
                entries = [
                    StreamEntry(
                        kenh: comm.kenh,
                        url: cachedURL,
                        urlFlv: isHLS ? nil : cachedURL,
                        urlHls: isHLS ? cachedURL : nil,
                        rawFlv: nil,
                        rawHls: cachedURL.hasPrefix("http") ? cachedURL : nil,
                        referer: nil,
                        livestreamId: comm.livestreamId,
                        title: match.title,
                        blv: comm.blv
                    )
                ]
            }

            for entry in entries {
                let entryCandidates = await buildCandidates(for: entry, commentator: comm, serverBaseURL: usedBase, includeProxyFallback: settings.autoFallbackToProxy)
                builtCandidates.append(contentsOf: entryCandidates)
            }

            // Chỉ thử tối đa 2 BLV để tránh chờ quá lâu nếu trận đã kết thúc
            if cIdx >= 1 && !builtCandidates.isEmpty {
                break
            }
        }

        guard session == playSessionID else { return }

        guard !builtCandidates.isEmpty else {
            isLoading = false
            errorMessage = "Trận đấu hiện chưa lên sóng hoặc không tìm thấy luồng phát hợp lệ."
            return
        }

        candidates = builtCandidates
        candidateIndex = 0
        tryCandidate(at: 0, session: session)
    }

    private func buildCandidates(
        for entry: StreamEntry,
        commentator: CommentatorItem,
        serverBaseURL: String,
        includeProxyFallback: Bool
    ) async -> [PlaybackCandidate] {
        var list: [PlaybackCandidate] = []
        let referer = entry.resolvedReferer

        var relayCandidate: PlaybackCandidate?
        if let rawHLS = entry.resolvedRawHLS,
           let proxyURL = try? await LocalHLSProxy.shared.buildProxiedStreamURL(rawHLS: rawHLS, referer: referer) {
            relayCandidate = PlaybackCandidate(
                url: proxyURL,
                headers: nil,
                label: "Trực tiếp • Không Proxy",
                isUsingServerProxy: false,
                commentator: commentator
            )
        }

        var directAVCandidate: PlaybackCandidate?
        if let rawHLS = entry.resolvedRawHLS, let rawURL = URL(string: rawHLS) {
            directAVCandidate = PlaybackCandidate(
                url: rawURL,
                headers: [
                    "Referer": referer,
                    "User-Agent": M3U8Rewriter.mobileUserAgent
                ],
                label: "Trực tiếp • AVPlayer",
                isUsingServerProxy: false,
                commentator: commentator
            )
        }

        var serverProxyCandidate: PlaybackCandidate?
        if let rawProxy = entry.urlHls ?? entry.url,
           let resolved = BongDaAPIClient.resolveServerURL(rawProxy, relativeToBase: serverBaseURL) {
            let host = resolved.host?.lowercased() ?? ""
            let isLoopback = (host == "127.0.0.1" || host == "localhost")
            if resolved.scheme?.lowercased() == "http",
               !isLoopback,
               let wrapped = try? await LocalHLSProxy.shared.buildProxiedStreamURL(rawHLS: resolved.absoluteString, referer: referer) {
                serverProxyCandidate = PlaybackCandidate(
                    url: wrapped,
                    headers: nil,
                    label: "Proxy Server (Dự phòng)",
                    isUsingServerProxy: true,
                    commentator: commentator
                )
            } else {
                serverProxyCandidate = PlaybackCandidate(
                    url: resolved,
                    headers: nil,
                    label: "Proxy Server (Dự phòng)",
                    isUsingServerProxy: true,
                    commentator: commentator
                )
            }
        }

        switch activeMode {
        case .directRelay:
            if let relayCandidate = relayCandidate { list.append(relayCandidate) }
            if let directAVCandidate = directAVCandidate { list.append(directAVCandidate) }
            if includeProxyFallback, let serverProxyCandidate = serverProxyCandidate { list.append(serverProxyCandidate) }
        case .directAVPlayer:
            if let directAVCandidate = directAVCandidate { list.append(directAVCandidate) }
            if let relayCandidate = relayCandidate { list.append(relayCandidate) }
            if includeProxyFallback, let serverProxyCandidate = serverProxyCandidate { list.append(serverProxyCandidate) }
        case .serverProxy:
            if let serverProxyCandidate = serverProxyCandidate { list.append(serverProxyCandidate) }
            if let relayCandidate = relayCandidate { list.append(relayCandidate) }
        }

        return list
    }

    private func tryCandidate(at index: Int, session: Int) {
        guard session == playSessionID else { return }
        cleanupObserversAndWatchdog()

        guard index < candidates.count else {
            isLoading = false
            errorMessage = "Không thể kết nối luồng phát. Có thể trận đấu chưa bắt đầu hoặc CDN đang bảo trì."
            return
        }

        candidateIndex = index
        let candidate = candidates[index]
        hasStartedPlaying = false
        isLoading = true
        errorMessage = nil
        selectedCommentator = candidate.commentator
        activeRouteLabel = candidate.label
        isUsingServerProxy = candidate.isUsingServerProxy
        statusText = "Đang tải \(candidate.label) (\(candidate.commentator.blv))..."

        let assetOptions: [String: Any]?
        if let headers = candidate.headers {
            assetOptions = ["AVURLAssetHTTPHeaderFieldsKey": headers]
        } else {
            assetOptions = nil
        }

        let asset = AVURLAsset(url: candidate.url, options: assetOptions)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 4.0

        let avPlayer: AVPlayer
        if let existing = self.player {
            existing.replaceCurrentItem(with: item)
            avPlayer = existing
        } else {
            avPlayer = AVPlayer(playerItem: item)
            avPlayer.automaticallyWaitsToMinimizeStalling = true
            self.player = avPlayer
        }

        avPlayer.isMuted = false
        avPlayer.volume = 1.0

        attachObservers(to: avPlayer, item: item, attemptIndex: index, session: session)
        startWatchdog(attemptIndex: index, session: session)
        avPlayer.play()
    }

    private func attachObservers(to avPlayer: AVPlayer, item: AVPlayerItem, attemptIndex: Int, session: Int) {
        itemStatusObserver = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            Task { @MainActor [weak self] in
                guard let self = self,
                      session == self.playSessionID,
                      attemptIndex == self.candidateIndex else { return }
                switch observedItem.status {
                case .readyToPlay:
                    self.markPlayingStarted()
                case .failed:
                    self.advanceToNextCandidate(session: session)
                default:
                    break
                }
            }
        }

        timeControlObserver = avPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] observedPlayer, _ in
            Task { @MainActor [weak self] in
                guard let self = self,
                      session == self.playSessionID,
                      attemptIndex == self.candidateIndex else { return }
                if observedPlayer.timeControlStatus == .playing {
                    self.markPlayingStarted()
                }
            }
        }

        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self,
                      session == self.playSessionID,
                      attemptIndex == self.candidateIndex else { return }
                if !self.hasStartedPlaying {
                    self.advanceToNextCandidate(session: session)
                }
            }
        }
    }

    private func startWatchdog(attemptIndex: Int, session: Int) {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            guard let self = self, !Task.isCancelled else { return }
            guard session == self.playSessionID,
                  attemptIndex == self.candidateIndex,
                  !self.hasStartedPlaying else { return }
            self.advanceToNextCandidate(session: session)
        }
    }

    private func markPlayingStarted() {
        hasStartedPlaying = true
        isLoading = false
        errorMessage = nil
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    private func advanceToNextCandidate(session: Int) {
        guard session == playSessionID, !hasStartedPlaying else { return }
        tryCandidate(at: candidateIndex + 1, session: session)
    }

    private func cleanupObserversAndWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        timeControlObserver?.invalidate()
        timeControlObserver = nil
        if let failureObserver = failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
            self.failureObserver = nil
        }
    }
}
