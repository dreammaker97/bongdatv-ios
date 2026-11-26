import XCTest
@testable import BongDaTV

final class BongDaTVTests: XCTestCase {
    func testMatchGrouperFiltersSortsAndGroupsCommentators() {
        let now: TimeInterval = 1_795_700_000
        let nowInt = Int(now)

        let items = [
            // Excluded basketball
            RawMatchItem(id: "b1", title: "Lakers vs Celtics", timestamp: nowInt + 100, matchId: "b1", sportType: "BASKETBALL"),
            // Excluded esports
            RawMatchItem(id: "e1", title: "T1 vs GenG", timestamp: nowInt + 100, matchId: "e1", sportType: "ESPORTS"),
            // Upcoming later
            RawMatchItem(id: "u2", title: "Arsenal vs Chelsea", timestamp: nowInt + 7200, blv: "TOM", livestreamId: "u2_a", matchId: "m_u2", sportType: "FOOTBALL"),
            // Upcoming sooner (same time football vs tennis -> football first)
            RawMatchItem(id: "t1", title: "Alcaraz vs Sinner", timestamp: nowInt + 3600, blv: "1 BLV", livestreamId: "t1", matchId: "m_t1", sportType: "TENNIS"),
            RawMatchItem(id: "u1", title: "Liverpool vs City", timestamp: nowInt + 3600, blv: "BLV A", livestreamId: "u1_a", matchId: "m_u1", sportType: "FOOTBALL"),
            // Live match with 2 commentators
            RawMatchItem(id: "l1_a", title: "Real Madrid vs Barca", timestamp: nowInt - 600, blv: "BLV 1", livestreamId: "l1_a", matchId: "m_l1", sportType: "FOOTBALL"),
            RawMatchItem(id: "l1_b", title: "Real Madrid vs Barca", timestamp: nowInt - 600, blv: "BLV 2", livestreamId: "l1_b", matchId: "m_l1", sportType: "FOOTBALL"),
            // Ended (< 9000s ago -> shown in Tier 3)
            RawMatchItem(id: "end1", title: "Inter vs Milan", timestamp: nowInt - 7500, blv: "1 BLV", livestreamId: "end1", matchId: "m_end1", sportType: "FOOTBALL"),
            // Hidden (> 9000s ago)
            RawMatchItem(id: "old1", title: "Very Old Match", timestamp: nowInt - 9500, blv: "1 BLV", livestreamId: "old1", matchId: "m_old1", sportType: "FOOTBALL"),
            // Timestamp 0 must never become ended
            RawMatchItem(id: "zero1", title: "TBD Match", timestamp: 0, blv: "1 BLV", livestreamId: "zero1", matchId: "m_zero1", sportType: "FOOTBALL")
        ]

        let grouped = MatchGrouper.groupAndSort(items, now: now)
        XCTAssertEqual(grouped.count, 6)
        XCTAssertEqual(grouped[0].title, "Real Madrid vs Barca")
        XCTAssertEqual(grouped[0].status(at: now), .live)
        XCTAssertEqual(grouped[0].commentators.count, 2)

        XCTAssertEqual(grouped[1].title, "Liverpool vs City")
        XCTAssertEqual(grouped[2].title, "Alcaraz vs Sinner")
        XCTAssertEqual(grouped[3].title, "Arsenal vs Chelsea")
        XCTAssertEqual(grouped[4].title, "TBD Match")
        XCTAssertEqual(grouped[4].status(at: now), .upcoming)
        XCTAssertEqual(grouped[5].title, "Inter vs Milan")
        XCTAssertEqual(grouped[5].status(at: now), .ended)
    }

    func testStreamEntryResolvedRefererPriority() {
        let withExplicit = StreamEntry(
            urlHls: "api.php?tab=stream&ref=aHR0cHM6Ly9vbGQub3Jn",
            rawHls: "https://cdn.example.com/live/ch1.m3u8",
            referer: "https://xoilac.domainkqt.cc/ajax/chanel/type/8/link/channel11"
        )
        XCTAssertEqual(withExplicit.resolvedReferer, "https://xoilac.domainkqt.cc/ajax/chanel/type/8/link/channel11")

        let encodedRef = M3U8Rewriter.base64URLEncode("https://xoilac.domainkqt.cc/player/1")
        let fromQuery = StreamEntry(
            urlHls: "/bongda/api.php?tab=stream&format=.m3u8&url=aHR0cHM6Ly9jZG4uZXhhbXBsZS5jb20vMS5tM3U4&ref=\(encodedRef)",
            referer: nil
        )
        XCTAssertEqual(fromQuery.resolvedReferer, "https://xoilac.domainkqt.cc/player/1")
        XCTAssertEqual(fromQuery.resolvedRawHLS, "https://cdn.example.com/1.m3u8")

        let fallback = StreamEntry(referer: nil)
        XCTAssertEqual(fallback.resolvedReferer, "https://xoilac.domainkqt.cc/")
    }

    func testM3U8RewriterRewritesMasterMediaAndKeyURIs() {
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-KEY:METHOD=AES-128,URI="/keys/enc.key"
        #EXT-X-STREAM-INF:BANDWIDTH=1800000
        https://edge.100ycdn.com/live1/channel60.m3u8?wsSecret=abc
        #EXTINF:2.0,
        seg_001.ts?token=xyz
        """
        let effectiveURL = URL(string: "https://live1.quickscoreboardz.com/live/channel60.m3u8")!
        let proxyBase = URL(string: "http://127.0.0.1:54321")!
        let referer = "https://xoilac.domainkqt.cc/"

        let rewritten = M3U8Rewriter.rewritePlaylist(
            playlist,
            effectiveURL: effectiveURL,
            referer: referer,
            proxyBaseURL: proxyBase
        )

        let lines = rewritten.components(separatedBy: "\n")
        XCTAssertTrue(lines[2].contains("URI=\"http://127.0.0.1:54321/hls?u="))
        XCTAssertTrue(lines[2].contains("&t=ts\""))
        XCTAssertTrue(lines[4].hasPrefix("http://127.0.0.1:54321/hls?u="))
        XCTAssertTrue(lines[4].hasSuffix("&t=m3u8"))
        XCTAssertTrue(lines[6].hasPrefix("http://127.0.0.1:54321/hls?u="))
        XCTAssertTrue(lines[6].hasSuffix("&t=ts"))

        let uQuery = URLComponents(string: lines[6])?.queryItems?.first(where: { $0.name == "u" })?.value
        XCTAssertEqual(M3U8Rewriter.base64URLDecode(uQuery ?? ""), "https://live1.quickscoreboardz.com/live/seg_001.ts?token=xyz")
    }

    func testLocalHLSProxyStartsAndRejectsInvalidRequests() async throws {
        let proxy = LocalHLSProxy()
        defer { proxy.stop() }

        let baseURL = try await proxy.ensureRunning()
        XCTAssertEqual(baseURL.host, "127.0.0.1")

        let pingURL = baseURL.appendingPathComponent("ping")
        let (pingData, pingResp) = try await URLSession.shared.data(from: pingURL)
        XCTAssertEqual((pingResp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: pingData, encoding: .utf8), "pong")

        let badURL = baseURL.appendingPathComponent("hls")
        let (_, badResp) = try await URLSession.shared.data(from: badURL)
        XCTAssertEqual((badResp as? HTTPURLResponse)?.statusCode, 400)
    }

    func testDecodeLeagueScheduleDictionaryAndMatchesResponse() throws {
        let leagueJSON = """
        {
          "time_update": "2026/11/26 11:00:00",
          "data": {
            "nha_1": {
              "id": "nha_1",
              "league": "Ngoại hạng Anh",
              "league_key": "nha",
              "league_short": "NHA",
              "round": "Vòng 12",
              "day": "26/11",
              "time": "22:00",
              "timestamp": 1795705200,
              "home": "Arsenal",
              "away": "Chelsea",
              "home_logo": "",
              "away_logo": "",
              "score_home": 2,
              "score_away": "1",
              "has_score": true,
              "channel": "K+",
              "status": "ended"
            }
          }
        }
        """
        let decodedLeague = try JSONDecoder().decode(LeagueScheduleResponse.self, from: Data(leagueJSON.utf8))
        XCTAssertEqual(decodedLeague.matches.count, 1)
        XCTAssertEqual(decodedLeague.matches[0].scoreHome, "2")
        XCTAssertEqual(decodedLeague.matches[0].scoreAway, "1")

        let emptyMatchesJSON = """
        {"time_update": "2026/11/26 11:00:00", "data": []}
        """
        let decodedEmpty = try JSONDecoder().decode(MatchesResponse.self, from: Data(emptyMatchesJSON.utf8))
        XCTAssertEqual(decodedEmpty.items.count, 0)
    }

    func testATSConfigurationAllowsPublicHTTP() {
        let ats = Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any]
        XCTAssertNotNil(ats, "NSAppTransportSecurity must be configured")
        XCTAssertEqual(ats?["NSAllowsArbitraryLoads"] as? Bool, true)
        XCTAssertNil(ats?["NSAllowsLocalNetworking"], "NSAllowsLocalNetworking overrides NSAllowsArbitraryLoads on iOS 10+ and breaks public HTTP URLs")
    }

    func testAPIClientPrioritizesLastWorkingBaseURL() {
        let lan = "http://192.168.1.210:8080/bongda"
        let remote = "http://example-remote.invalid:8080/bongda"
        let baseList = [lan, remote]

        XCTAssertEqual(BongDaAPIClient.prioritizedBaseURLs(baseList, preferred: nil), [lan, remote])
        XCTAssertEqual(BongDaAPIClient.prioritizedBaseURLs(baseList, preferred: remote), [remote, lan])
        XCTAssertEqual(BongDaAPIClient.prioritizedBaseURLs(baseList, preferred: "http://other.invalid"), [lan, remote])
    }
}
