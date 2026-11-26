import Foundation

struct FlexibleInt: Decodable {
    let value: Int

    init(_ value: Int) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            value = intVal
        } else if let doubleVal = try? container.decode(Double.self) {
            value = Int(doubleVal)
        } else if let strVal = try? container.decode(String.self), let parsed = Int(strVal.trimmingCharacters(in: .whitespacesAndNewlines)) {
            value = parsed
        } else {
            value = 0
        }
    }
}

struct FlexibleString: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            value = s
        } else if let i = try? container.decode(Int.self) {
            value = String(i)
        } else if let d = try? container.decode(Double.self) {
            value = String(Int(d))
        } else {
            value = ""
        }
    }
}

struct RawMatchItem: Decodable, Hashable {
    let id: String
    let title: String
    let timestamp: Int
    let time: String
    let date: String
    let giai: String
    let blv: String
    let commentatorSlug: String
    let livestreamId: String
    let matchId: String
    let slug: String
    let url: String?
    let urlHls: String?
    let kenh: String
    let sportType: String
    let sportName: String

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case timestamp
        case time
        case date
        case giai
        case blv
        case commentatorSlug = "commentator_slug"
        case livestreamId = "livestream_id"
        case matchId = "match_id"
        case slug
        case url
        case urlHls = "url_hls"
        case kenh
        case sportType = "sport_type"
        case sportName = "sport_name"
    }

    init(
        id: String,
        title: String,
        timestamp: Int,
        time: String = "",
        date: String = "",
        giai: String = "",
        blv: String = "1 BLV",
        commentatorSlug: String = "",
        livestreamId: String = "",
        matchId: String = "",
        slug: String = "",
        url: String? = nil,
        urlHls: String? = nil,
        kenh: String = "",
        sportType: String = "FOOTBALL",
        sportName: String = "Bóng đá"
    ) {
        self.id = id
        self.title = title
        self.timestamp = timestamp
        self.time = time
        self.date = date
        self.giai = giai
        self.blv = blv
        self.commentatorSlug = commentatorSlug
        self.livestreamId = livestreamId
        self.matchId = matchId
        self.slug = slug
        self.url = url
        self.urlHls = urlHls
        self.kenh = kenh
        self.sportType = sportType
        self.sportName = sportName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Chưa rõ trận"
        timestamp = (try c.decodeIfPresent(FlexibleInt.self, forKey: .timestamp))?.value ?? 0
        time = try c.decodeIfPresent(String.self, forKey: .time) ?? ""
        date = try c.decodeIfPresent(String.self, forKey: .date) ?? ""
        giai = try c.decodeIfPresent(String.self, forKey: .giai) ?? ""
        blv = try c.decodeIfPresent(String.self, forKey: .blv) ?? "1 BLV"
        commentatorSlug = try c.decodeIfPresent(String.self, forKey: .commentatorSlug) ?? ""
        livestreamId = try c.decodeIfPresent(String.self, forKey: .livestreamId) ?? id
        matchId = try c.decodeIfPresent(String.self, forKey: .matchId) ?? ""
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url)
        urlHls = try c.decodeIfPresent(String.self, forKey: .urlHls)
        kenh = try c.decodeIfPresent(String.self, forKey: .kenh) ?? ""
        sportType = try c.decodeIfPresent(String.self, forKey: .sportType) ?? "FOOTBALL"
        sportName = try c.decodeIfPresent(String.self, forKey: .sportName) ?? "Bóng đá"
    }
}

struct MatchesResponse: Decodable {
    let items: [RawMatchItem]
    let timeUpdate: String

    enum CodingKeys: String, CodingKey {
        case data
        case timeUpdate = "time_update"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timeUpdate = try c.decodeIfPresent(String.self, forKey: .timeUpdate) ?? ""
        if let dict = try? c.decode([String: RawMatchItem].self, forKey: .data) {
            items = Array(dict.values)
        } else if let arr = try? c.decode([RawMatchItem].self, forKey: .data) {
            items = arr
        } else {
            items = []
        }
    }
}

enum MatchStatus: Int, Comparable, Hashable {
    case live = 1
    case upcoming = 2
    case ended = 3

    static func < (lhs: MatchStatus, rhs: MatchStatus) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var badgeText: String {
        switch self {
        case .live: return "Đang đá"
        case .upcoming: return "Sắp đá"
        case .ended: return "Hết giờ"
        }
    }
}

struct CommentatorItem: Identifiable, Hashable {
    let id: String
    let blv: String
    let kenh: String
    let livestreamId: String
    let url: String?
    let urlHls: String?
}

struct MatchGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let timestamp: Int
    let timeText: String
    let dateText: String
    let giai: String
    let sportType: String
    let sportName: String
    let commentators: [CommentatorItem]

    func status(at now: TimeInterval = Date().timeIntervalSince1970) -> MatchStatus {
        guard timestamp > 0 else { return .upcoming }
        let nowSec = Int(now)
        if nowSec >= timestamp && nowSec < timestamp + 7200 {
            return .live
        } else if nowSec >= timestamp + 7200 {
            return .ended
        }
        return .upcoming
    }

    var sportIcon: String {
        switch sportType.uppercased() {
        case "TENNIS": return "🎾"
        case "VOLLEYBALL": return "🏐"
        case "BADMINTON": return "🏸"
        case "TABLETENNIS": return "🏓"
        case "BASEBALL": return "⚾"
        default: return "⚽"
        }
    }

    var displayCompetition: String {
        let trimmed = giai.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? sportName : trimmed
    }

    var displayTimeAndDate: String {
        if timestamp > 0 {
            let d = Date(timeIntervalSince1970: TimeInterval(timestamp))
            let tf = Self.timeFormatter.string(from: d)
            let df = Self.dateFormatter.string(from: d)
            return "\(tf) • \(df)"
        }
        if !timeText.isEmpty && !dateText.isEmpty {
            return "\(timeText) • \(dateText)"
        }
        return timeText.isEmpty ? "Chưa rõ giờ" : timeText
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "vi_VN")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "vi_VN")
        f.dateFormat = "dd/MM"
        return f
    }()
}

enum MatchGrouper {
    static let excludedSports: Set<String> = [
        "basketball", "esports", "csgo", "cs2", "dota2", "dota",
        "lol", "game", "gaming", "valorant", "pubg", "aov", "fifa"
    ]

    static func isExcludedSport(_ sport: String) -> Bool {
        excludedSports.contains(sport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func groupAndSort(_ rawItems: [RawMatchItem], now: TimeInterval = Date().timeIntervalSince1970) -> [MatchGroup] {
        let nowSec = Int(now)
        var buckets: [String: (sample: RawMatchItem, commentators: [CommentatorItem])] = [:]

        for item in rawItems {
            if isExcludedSport(item.sportType) {
                continue
            }
            if item.timestamp > 0 && nowSec > item.timestamp + 9000 {
                continue
            }

            let key: String
            if !item.matchId.isEmpty {
                key = "match_id_\(item.matchId)"
            } else if !item.slug.isEmpty {
                key = "slug_\(item.slug)"
            } else {
                key = "title_time_\(item.title)_\(item.timestamp)"
            }

            let commId = item.livestreamId.isEmpty ? (item.id.isEmpty ? UUID().uuidString : item.id) : item.livestreamId
            let comm = CommentatorItem(
                id: commId,
                blv: item.blv.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "1 BLV" : item.blv,
                kenh: item.kenh,
                livestreamId: commId,
                url: item.url,
                urlHls: item.urlHls
            )

            if var existing = buckets[key] {
                if !existing.commentators.contains(where: { $0.id == comm.id && $0.blv == comm.blv }) {
                    existing.commentators.append(comm)
                    buckets[key] = existing
                }
            } else {
                buckets[key] = (item, [comm])
            }
        }

        let groups = buckets.map { key, value in
            MatchGroup(
                id: key,
                title: value.sample.title,
                timestamp: value.sample.timestamp,
                timeText: value.sample.time,
                dateText: value.sample.date,
                giai: value.sample.giai,
                sportType: value.sample.sportType.isEmpty ? "FOOTBALL" : value.sample.sportType,
                sportName: value.sample.sportName.isEmpty ? "Bóng đá" : value.sample.sportName,
                commentators: value.commentators
            )
        }

        return groups.sorted { lhs, rhs in
            let sA = lhs.status(at: now)
            let sB = rhs.status(at: now)
            if sA != sB {
                return sA < sB
            }
            if lhs.timestamp != rhs.timestamp {
                if lhs.timestamp == 0 { return false }
                if rhs.timestamp == 0 { return true }
                return lhs.timestamp < rhs.timestamp
            }
            let fbA = lhs.sportType.uppercased() == "FOOTBALL" || lhs.sportType.isEmpty ? 0 : 1
            let fbB = rhs.sportType.uppercased() == "FOOTBALL" || rhs.sportType.isEmpty ? 0 : 1
            if fbA != fbB {
                return fbA < fbB
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}

struct StreamEntry: Decodable, Identifiable, Hashable {
    let kenh: String
    let url: String?
    let urlFlv: String?
    let urlHls: String?
    let rawFlv: String?
    let rawHls: String?
    let referer: String?
    let livestreamId: String
    let title: String
    let blv: String

    var id: String {
        if !livestreamId.isEmpty { return "\(livestreamId)_\(blv)_\(kenh)" }
        return urlHls ?? url ?? rawHls ?? UUID().uuidString
    }

    enum CodingKeys: String, CodingKey {
        case kenh
        case url
        case urlFlv = "url_flv"
        case urlHls = "url_hls"
        case rawFlv = "raw_flv"
        case rawHls = "raw_hls"
        case referer
        case livestreamId = "livestream_id"
        case title
        case blv
    }

    init(
        kenh: String = "",
        url: String? = nil,
        urlFlv: String? = nil,
        urlHls: String? = nil,
        rawFlv: String? = nil,
        rawHls: String? = nil,
        referer: String? = nil,
        livestreamId: String = "",
        title: String = "",
        blv: String = ""
    ) {
        self.kenh = kenh
        self.url = url
        self.urlFlv = urlFlv
        self.urlHls = urlHls
        self.rawFlv = rawFlv
        self.rawHls = rawHls
        self.referer = referer
        self.livestreamId = livestreamId
        self.title = title
        self.blv = blv
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kenh = try c.decodeIfPresent(String.self, forKey: .kenh) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url)
        urlFlv = try c.decodeIfPresent(String.self, forKey: .urlFlv)
        urlHls = try c.decodeIfPresent(String.self, forKey: .urlHls)
        rawFlv = try c.decodeIfPresent(String.self, forKey: .rawFlv)
        rawHls = try c.decodeIfPresent(String.self, forKey: .rawHls)
        referer = try c.decodeIfPresent(String.self, forKey: .referer)
        livestreamId = try c.decodeIfPresent(String.self, forKey: .livestreamId) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        blv = try c.decodeIfPresent(String.self, forKey: .blv) ?? ""
    }

    var resolvedReferer: String {
        if let ref = referer?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty {
            return ref
        }
        for candidate in [urlHls, url, urlFlv] {
            guard let raw = candidate,
                  let comps = URLComponents(string: raw),
                  let encodedRef = comps.queryItems?.first(where: { $0.name == "ref" })?.value,
                  let decoded = M3U8Rewriter.base64URLDecode(encodedRef),
                  decoded.hasPrefix("http") else {
                continue
            }
            return decoded
        }
        return "https://xoilac.domainkqt.cc/"
    }

    var resolvedRawHLS: String? {
        if let hls = rawHls?.trimmingCharacters(in: .whitespacesAndNewlines), !hls.isEmpty {
            return hls
        }
        if let flv = rawFlv?.trimmingCharacters(in: .whitespacesAndNewlines), flv.contains(".flv") {
            return flv.replacingOccurrences(of: ".flv", with: ".m3u8")
        }
        for candidate in [urlHls, url] {
            guard let raw = candidate,
                  let comps = URLComponents(string: raw),
                  let encodedUrl = comps.queryItems?.first(where: { $0.name == "url" })?.value,
                  let decoded = M3U8Rewriter.base64URLDecode(encodedUrl),
                  decoded.hasPrefix("http") else {
                continue
            }
            return decoded.contains(".flv") ? decoded.replacingOccurrences(of: ".flv", with: ".m3u8") : decoded
        }
        return nil
    }
}

struct GetLinkResponse: Decodable {
    let data: [StreamEntry]
}

struct LeagueMatchItem: Decodable, Identifiable, Hashable {
    let id: String
    let league: String
    let leagueKey: String
    let leagueShort: String
    let round: String
    let day: String
    let time: String
    let timestamp: Int
    let home: String
    let away: String
    let homeLogo: String
    let awayLogo: String
    let scoreHome: String?
    let scoreAway: String?
    let hasScore: Bool
    let channel: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case id
        case league
        case leagueKey = "league_key"
        case leagueShort = "league_short"
        case round
        case day
        case time
        case timestamp
        case home
        case away
        case homeLogo = "home_logo"
        case awayLogo = "away_logo"
        case scoreHome = "score_home"
        case scoreAway = "score_away"
        case hasScore = "has_score"
        case channel
        case status
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        league = try c.decodeIfPresent(String.self, forKey: .league) ?? ""
        leagueKey = try c.decodeIfPresent(String.self, forKey: .leagueKey) ?? ""
        leagueShort = try c.decodeIfPresent(String.self, forKey: .leagueShort) ?? ""
        round = try c.decodeIfPresent(String.self, forKey: .round) ?? ""
        day = try c.decodeIfPresent(String.self, forKey: .day) ?? ""
        time = try c.decodeIfPresent(String.self, forKey: .time) ?? ""
        timestamp = (try c.decodeIfPresent(FlexibleInt.self, forKey: .timestamp))?.value ?? 0
        home = try c.decodeIfPresent(String.self, forKey: .home) ?? ""
        away = try c.decodeIfPresent(String.self, forKey: .away) ?? ""
        homeLogo = try c.decodeIfPresent(String.self, forKey: .homeLogo) ?? ""
        awayLogo = try c.decodeIfPresent(String.self, forKey: .awayLogo) ?? ""
        let sh = try c.decodeIfPresent(FlexibleString.self, forKey: .scoreHome)?.value
        let sa = try c.decodeIfPresent(FlexibleString.self, forKey: .scoreAway)?.value
        scoreHome = (sh?.isEmpty == false) ? sh : nil
        scoreAway = (sa?.isEmpty == false) ? sa : nil
        hasScore = try c.decodeIfPresent(Bool.self, forKey: .hasScore) ?? false
        channel = try c.decodeIfPresent(String.self, forKey: .channel) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "upcoming"
    }
}

struct LeagueScheduleResponse: Decodable {
    let matches: [LeagueMatchItem]
    let timeUpdate: String

    enum CodingKeys: String, CodingKey {
        case data
        case timeUpdate = "time_update"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timeUpdate = try c.decodeIfPresent(String.self, forKey: .timeUpdate) ?? ""
        if let dict = try? c.decode([String: LeagueMatchItem].self, forKey: .data) {
            matches = dict.values.sorted { $0.timestamp < $1.timestamp }
        } else if let arr = try? c.decode([LeagueMatchItem].self, forKey: .data) {
            matches = arr.sorted { $0.timestamp < $1.timestamp }
        } else {
            matches = []
        }
    }
}
