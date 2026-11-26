import Foundation

enum PlaybackMode: String, CaseIterable, Identifiable, Codable {
    case directRelay = "direct_relay"
    case directAVPlayer = "direct_avplayer"
    case serverProxy = "server_proxy"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .directRelay:
            return "Trực tiếp (Không Proxy Server)"
        case .directAVPlayer:
            return "Trực tiếp (AVPlayer Header)"
        case .serverProxy:
            return "Proxy qua Server"
        }
    }

    var shortBadge: String {
        switch self {
        case .directRelay:
            return "Trực tiếp • Không Proxy"
        case .directAVPlayer:
            return "Trực tiếp • AVPlayer"
        case .serverProxy:
            return "Proxy Server"
        }
    }

    var subtitle: String {
        switch self {
        case .directRelay:
            return "Khuyên dùng: Proxy mini ngay trên iPhone gắn Referer, tải video thẳng từ CDN."
        case .directAVPlayer:
            return "Thử đưa header Referer trực tiếp vào AVPlayer (một số CDN con có thể chặn)."
        case .serverProxy:
            return "Chuyển toàn bộ luồng video đi qua máy chủ cá nhân (tốn băng thông server)."
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let defaultLANServerURL = "http://192.168.1.210:8080/bongda"

    private enum Keys {
        static let serverURL = "bongdatv.serverURL"
        static let secondaryServerURL = "bongdatv.secondaryServerURL"
        static let playbackMode = "bongdatv.playbackMode"
        static let autoFallbackToProxy = "bongdatv.autoFallbackToProxy"
    }

    @Published var serverURL: String {
        didSet {
            UserDefaults.standard.set(Self.normalizeBaseURL(serverURL), forKey: Keys.serverURL)
        }
    }

    @Published var secondaryServerURL: String {
        didSet {
            UserDefaults.standard.set(Self.normalizeBaseURL(secondaryServerURL), forKey: Keys.secondaryServerURL)
        }
    }

    @Published var playbackMode: PlaybackMode {
        didSet {
            UserDefaults.standard.set(playbackMode.rawValue, forKey: Keys.playbackMode)
        }
    }

    @Published var autoFallbackToProxy: Bool {
        didSet {
            UserDefaults.standard.set(autoFallbackToProxy, forKey: Keys.autoFallbackToProxy)
        }
    }

    init() {
        let defaults = UserDefaults.standard
        let savedPrimary = defaults.string(forKey: Keys.serverURL) ?? Self.defaultLANServerURL
        self.serverURL = Self.normalizeBaseURL(savedPrimary).isEmpty ? Self.defaultLANServerURL : Self.normalizeBaseURL(savedPrimary)
        self.secondaryServerURL = Self.normalizeBaseURL(defaults.string(forKey: Keys.secondaryServerURL) ?? "")
        if let rawMode = defaults.string(forKey: Keys.playbackMode), let parsed = PlaybackMode(rawValue: rawMode) {
            self.playbackMode = parsed
        } else {
            self.playbackMode = .directRelay
        }
        if defaults.object(forKey: Keys.autoFallbackToProxy) == nil {
            self.autoFallbackToProxy = true
        } else {
            self.autoFallbackToProxy = defaults.bool(forKey: Keys.autoFallbackToProxy)
        }
    }

    var candidateBaseURLs: [String] {
        var list: [String] = []
        let primary = Self.normalizeBaseURL(serverURL)
        if !primary.isEmpty {
            list.append(primary)
        }
        let secondary = Self.normalizeBaseURL(secondaryServerURL)
        if !secondary.isEmpty && !list.contains(secondary) {
            list.append(secondary)
        }
        return list
    }

    static func normalizeBaseURL(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    func resetDefaults() {
        serverURL = Self.defaultLANServerURL
        secondaryServerURL = ""
        playbackMode = .directRelay
        autoFallbackToProxy = true
    }
}
