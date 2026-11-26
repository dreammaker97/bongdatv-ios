import Foundation

enum APIError: LocalizedError {
    case noServerConfigured
    case invalidURL(String)
    case httpError(Int)
    case emptyStreams
    case allServersFailed(String)

    var errorDescription: String? {
        switch self {
        case .noServerConfigured:
            return "Chưa cấu hình địa chỉ máy chủ trong Cài đặt."
        case .invalidURL(let url):
            return "Địa chỉ máy chủ không hợp lệ: \(url)"
        case .httpError(let code):
            return "Máy chủ trả về mã lỗi HTTP \(code)."
        case .emptyStreams:
            return "Trận đấu hiện chưa có luồng phát."
        case .allServersFailed(let reason):
            return "Không thể kết nối máy chủ: \(reason)"
        }
    }
}

final class BongDaAPIClient {
    private static let stateLock = NSLock()
    private static var lastWorkingBaseURL: String?

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    static func prioritizedBaseURLs(_ baseURLs: [String], preferred: String?) -> [String] {
        guard let preferred = preferred,
              !preferred.isEmpty,
              let idx = baseURLs.firstIndex(of: preferred),
              idx > 0 else {
            return baseURLs
        }
        var reordered = baseURLs
        let item = reordered.remove(at: idx)
        reordered.insert(item, at: 0)
        return reordered
    }

    private static func currentPreferredBaseURL() -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastWorkingBaseURL
    }

    private static func recordWorkingBaseURL(_ url: String) {
        stateLock.lock()
        defer { stateLock.unlock() }
        lastWorkingBaseURL = url
    }

    func fetchMatches(baseURLs: [String], forceUpdate: Bool = false) async throws -> (groups: [MatchGroup], timeUpdate: String, usedBaseURL: String) {
        let suffix = forceUpdate ? "api.php?tab=matches&server=xoilactv&devmode=update" : "api.php?tab=matches&server=xoilactv"
        let (data, usedBase) = try await fetchWithFailover(baseURLs: baseURLs, relativePath: suffix)
        let decoded = try JSONDecoder().decode(MatchesResponse.self, from: data)
        let groups = MatchGrouper.groupAndSort(decoded.items)
        return (groups, decoded.timeUpdate, usedBase)
    }

    func fetchStreams(baseURLs: [String], livestreamID: String) async throws -> (entries: [StreamEntry], usedBaseURL: String) {
        let encoded = livestreamID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? livestreamID
        let suffix = "api.php?tab=getlink&server=xoilactv&livestream_id=\(encoded)"
        let (data, usedBase) = try await fetchWithFailover(baseURLs: baseURLs, relativePath: suffix)
        let decoded = try JSONDecoder().decode(GetLinkResponse.self, from: data)
        return (decoded.data, usedBase)
    }

    func fetchLeagueSchedule(baseURLs: [String], forceUpdate: Bool = false) async throws -> (matches: [LeagueMatchItem], timeUpdate: String, usedBaseURL: String) {
        let suffix = forceUpdate ? "api.php?tab=league_schedule&server=24h&devmode=update" : "api.php?tab=league_schedule&server=24h"
        let (data, usedBase) = try await fetchWithFailover(baseURLs: baseURLs, relativePath: suffix)
        let decoded = try JSONDecoder().decode(LeagueScheduleResponse.self, from: data)
        return (decoded.matches, decoded.timeUpdate, usedBase)
    }

    func triggerCronUpdate(baseURLs: [String]) async throws -> (summary: String, usedBaseURL: String) {
        let (data, usedBase) = try await fetchWithFailover(baseURLs: baseURLs, relativePath: "cron_update.php", timeoutOverride: 45)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let servers = json["servers"] as? [String: Any],
           let xoilac = servers["xoilactv"] as? [String: Any] {
            let count = xoilac["matches_count"] as? Int ?? 0
            let live = xoilac["live_count"] as? Int ?? 0
            let domain = xoilac["active_domain"] as? String ?? ""
            return ("Cập nhật \(count) trận (\(live) đang đá) • Nguồn: \(domain)", usedBase)
        }
        return ("Đã làm mới dữ liệu trên máy chủ.", usedBase)
    }

    func testConnection(baseURL: String) async throws -> String {
        let normalized = AppSettings.normalizeBaseURL(baseURL)
        guard !normalized.isEmpty else {
            throw APIError.noServerConfigured
        }
        let (data, used) = try await fetchSingle(baseURL: normalized, relativePath: "api.php?tab=matches&server=xoilactv", timeout: 5)
        Self.recordWorkingBaseURL(used)
        let decoded = try JSONDecoder().decode(MatchesResponse.self, from: data)
        return "Kết nối OK • \(decoded.items.count) luồng trận (cập nhật: \(decoded.timeUpdate))"
    }

    static func resolveServerURL(_ rawOrRelative: String, relativeToBase baseURL: String) -> URL? {
        let trimmed = rawOrRelative.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return URL(string: trimmed)
        }
        guard let base = URL(string: AppSettings.normalizeBaseURL(baseURL)) else { return nil }
        if trimmed.hasPrefix("/") {
            var comps = URLComponents()
            comps.scheme = base.scheme
            comps.host = base.host
            comps.port = base.port
            guard let origin = comps.url else { return nil }
            return URL(string: trimmed, relativeTo: origin)?.absoluteURL
        }
        let clean = trimmed.hasPrefix("./") ? String(trimmed.dropFirst(2)) : trimmed
        return URL(string: "\(base.absoluteString)/\(clean)")
    }

    private func fetchWithFailover(baseURLs: [String], relativePath: String, timeoutOverride: TimeInterval? = nil) async throws -> (Data, String) {
        guard !baseURLs.isEmpty else {
            throw APIError.noServerConfigured
        }
        let ordered = Self.prioritizedBaseURLs(baseURLs, preferred: Self.currentPreferredBaseURL())
        var lastError: Error = APIError.noServerConfigured
        for (index, base) in ordered.enumerated() {
            let hasFallback = index < ordered.count - 1
            let timeout = timeoutOverride ?? (hasFallback ? 2.0 : 14.0)
            do {
                let result = try await fetchSingle(baseURL: base, relativePath: relativePath, timeout: timeout)
                Self.recordWorkingBaseURL(result.1)
                return result
            } catch {
                lastError = error
            }
        }
        throw APIError.allServersFailed(lastError.localizedDescription)
    }

    private func fetchSingle(baseURL: String, relativePath: String, timeout: TimeInterval) async throws -> (Data, String) {
        let normalizedBase = AppSettings.normalizeBaseURL(baseURL)
        let fullStr = "\(normalizedBase)/\(relativePath)"
        guard let url = URL(string: fullStr) else {
            throw APIError.invalidURL(fullStr)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw APIError.httpError(http.statusCode)
        }
        return (data, normalizedBase)
    }
}
