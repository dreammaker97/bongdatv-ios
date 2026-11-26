import Foundation
import Network

struct M3U8Rewriter {
    static let mobileUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    static func base64URLEncode(_ string: String) -> String {
        let data = Data(string.utf8)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ string: String) -> String? {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let unescaped = s.removingPercentEncoding {
            s = unescaped
        }
        s = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder > 0 {
            s += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: s, options: .ignoreUnknownCharacters) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func resolveURL(_ line: String, relativeTo baseURL: URL) -> URL? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return URL(string: trimmed)
        }
        if trimmed.hasPrefix("//"), let scheme = baseURL.scheme {
            return URL(string: "\(scheme):\(trimmed)")
        }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
    }

    static func buildProxyURI(targetURL: URL, referer: String, proxyBaseURL: URL) -> String {
        let isPlaylist = targetURL.pathExtension.lowercased() == "m3u8"
            || targetURL.absoluteString.lowercased().contains(".m3u8")
        let typeParam = isPlaylist ? "m3u8" : "ts"
        let u = base64URLEncode(targetURL.absoluteString)
        let r = base64URLEncode(referer)
        let base = proxyBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(base)/hls?u=\(u)&r=\(r)&t=\(typeParam)"
    }

    static func rewritePlaylist(_ body: String, effectiveURL: URL, referer: String, proxyBaseURL: URL) -> String {
        let normalized = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var output: [String] = []
        output.reserveCapacity(lines.count)

        let uriRegex = try? NSRegularExpression(pattern: #"URI="([^"]+)""#, options: [.caseInsensitive])

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                output.append("")
                continue
            }

            if trimmed.hasPrefix("#") {
                if let regex = uriRegex, trimmed.range(of: "URI=\"", options: .caseInsensitive) != nil {
                    let nsLine = trimmed as NSString
                    let matches = regex.matches(in: trimmed, range: NSRange(location: 0, length: nsLine.length))
                    if !matches.isEmpty {
                        var rewritten = trimmed
                        for match in matches.reversed() {
                            guard match.numberOfRanges >= 2,
                                  let fullRange = Range(match.range(at: 0), in: rewritten),
                                  let valueRange = Range(match.range(at: 1), in: rewritten) else {
                                continue
                            }
                            let rawURI = String(rewritten[valueRange])
                            if let absURL = resolveURL(rawURI, relativeTo: effectiveURL) {
                                let proxied = buildProxyURI(targetURL: absURL, referer: referer, proxyBaseURL: proxyBaseURL)
                                rewritten.replaceSubrange(fullRange, with: "URI=\"\(proxied)\"")
                            }
                        }
                        output.append(rewritten)
                        continue
                    }
                }
                output.append(trimmed)
                continue
            }

            if let absURL = resolveURL(trimmed, relativeTo: effectiveURL) {
                output.append(buildProxyURI(targetURL: absURL, referer: referer, proxyBaseURL: proxyBaseURL))
            } else {
                output.append(trimmed)
            }
        }

        return output.joined(separator: "\n")
    }
}

private final class RedirectHeaderPreservingDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var updated = request
        if let originalHeaders = task.originalRequest?.allHTTPHeaderFields {
            for key in ["Referer", "Origin", "User-Agent", "Range"] {
                if let value = originalHeaders[key], !value.isEmpty {
                    updated.setValue(value, forHTTPHeaderField: key)
                }
            }
        }
        completionHandler(updated)
    }
}

final class LocalHLSProxy: @unchecked Sendable {
    static let shared = LocalHLSProxy()

    private let stateQueue = DispatchQueue(label: "com.bongdatv.localproxy.state")
    private let connectionQueue = DispatchQueue(label: "com.bongdatv.localproxy.conn", attributes: .concurrent)
    private let redirectDelegate = RedirectHeaderPreservingDelegate()
    private lazy var upstreamSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 25
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        return URLSession(configuration: config, delegate: redirectDelegate, delegateQueue: nil)
    }()

    private var listener: NWListener?
    private var boundPort: UInt16?
    private var pendingWaiters: [CheckedContinuation<URL, Error>] = []
    private var isStarting = false

    init() {}

    var currentBaseURL: URL? {
        stateQueue.sync {
            guard let port = boundPort else { return nil }
            return URL(string: "http://127.0.0.1:\(port)")
        }
    }

    func ensureRunning() async throws -> URL {
        return try await withCheckedThrowingContinuation { continuation in
            stateQueue.async {
                if let port = self.boundPort, self.listener != nil, let url = URL(string: "http://127.0.0.1:\(port)") {
                    continuation.resume(returning: url)
                    return
                }
                self.pendingWaiters.append(continuation)
                guard !self.isStarting else { return }
                self.isStarting = true
                self.startListenerLocked()
            }
        }
    }

    func stop() {
        stateQueue.async {
            self.listener?.cancel()
            self.listener = nil
            self.boundPort = nil
            self.isStarting = false
        }
    }

    func buildProxiedStreamURL(rawHLS: String, referer: String) async throws -> URL {
        let baseURL = try await ensureRunning()
        guard let targetURL = URL(string: rawHLS) else {
            throw URLError(.badURL)
        }
        let u = M3U8Rewriter.base64URLEncode(targetURL.absoluteString)
        let r = M3U8Rewriter.base64URLEncode(referer)
        let baseStr = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let result = URL(string: "\(baseStr)/hls?u=\(u)&r=\(r)&t=m3u8") else {
            throw URLError(.badURL)
        }
        return result
    }

    private func startListenerLocked() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"), port: .any)

            let newListener = try NWListener(using: params)
            self.listener = newListener

            newListener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                self.stateQueue.async {
                    switch state {
                    case .ready:
                        if let port = newListener.port?.rawValue,
                           let url = URL(string: "http://127.0.0.1:\(port)") {
                            self.boundPort = port
                            self.isStarting = false
                            let waiters = self.pendingWaiters
                            self.pendingWaiters.removeAll()
                            waiters.forEach { $0.resume(returning: url) }
                        }
                    case .failed(let error):
                        self.listener = nil
                        self.boundPort = nil
                        self.isStarting = false
                        let waiters = self.pendingWaiters
                        self.pendingWaiters.removeAll()
                        waiters.forEach { $0.resume(throwing: error) }
                    case .cancelled:
                        self.listener = nil
                        self.boundPort = nil
                        self.isStarting = false
                    default:
                        break
                    }
                }
            }

            newListener.newConnectionHandler = { [weak self] conn in
                self?.handleConnection(conn)
            }

            newListener.start(queue: connectionQueue)
        } catch {
            self.listener = nil
            self.boundPort = nil
            self.isStarting = false
            let waiters = self.pendingWaiters
            self.pendingWaiters.removeAll()
            waiters.forEach { $0.resume(throwing: error) }
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: connectionQueue)
        receiveHTTPRequest(connection: connection, buffer: Data())
    }

    private func receiveHTTPRequest(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self = self else {
                connection.cancel()
                return
            }
            var accumulated = buffer
            if let data = data, !data.isEmpty {
                accumulated.append(data)
            }

            if let headerEnd = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = accumulated.subdata(in: 0..<headerEnd.lowerBound)
                self.processRequestHeader(headerData: headerData, connection: connection)
                return
            }

            if isComplete || error != nil || accumulated.count > 65536 {
                connection.cancel()
                return
            }

            self.receiveHTTPRequest(connection: connection, buffer: accumulated)
        }
    }

    private func processRequestHeader(headerData: Data, connection: NWConnection) {
        guard let rawHeader = String(data: headerData, encoding: .utf8) else {
            sendTextResponse(connection: connection, status: "400 Bad Request", body: "Invalid request encoding")
            return
        }

        let lines = rawHeader.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendTextResponse(connection: connection, status: "400 Bad Request", body: "Empty request")
            return
        }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            sendTextResponse(connection: connection, status: "400 Bad Request", body: "Malformed request line")
            return
        }

        let method = String(parts[0]).uppercased()
        let rawTarget = String(parts[1])

        guard method == "GET" || method == "HEAD" else {
            sendTextResponse(connection: connection, status: "405 Method Not Allowed", body: "Method not allowed")
            return
        }

        var requestHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                requestHeaders[key] = value
            }
        }

        guard let components = URLComponents(string: "http://127.0.0.1\(rawTarget)") else {
            sendTextResponse(connection: connection, status: "400 Bad Request", body: "Invalid URL")
            return
        }

        if components.path == "/ping" {
            sendTextResponse(connection: connection, status: "200 OK", body: "pong")
            return
        }

        guard components.path == "/hls",
              let uParam = components.queryItems?.first(where: { $0.name == "u" })?.value,
              let targetString = M3U8Rewriter.base64URLDecode(uParam),
              let targetURL = URL(string: targetString),
              let scheme = targetURL.scheme?.lowercased(),
              (scheme == "http" || scheme == "https") else {
            sendTextResponse(connection: connection, status: "400 Bad Request", body: "Missing or invalid stream URL")
            return
        }

        let rParam = components.queryItems?.first(where: { $0.name == "r" })?.value ?? ""
        let referer = M3U8Rewriter.base64URLDecode(rParam) ?? "https://xoilac.domainkqt.cc/"
        let typeParam = (components.queryItems?.first(where: { $0.name == "t" })?.value ?? "").lowercased()

        var upstreamReq = URLRequest(url: targetURL)
        upstreamReq.httpMethod = method
        upstreamReq.setValue(M3U8Rewriter.mobileUserAgent, forHTTPHeaderField: "User-Agent")
        upstreamReq.setValue(referer, forHTTPHeaderField: "Referer")
        if let refURL = URL(string: referer), let refScheme = refURL.scheme, let refHost = refURL.host {
            let portSuffix = refURL.port.map { ":\($0)" } ?? ""
            upstreamReq.setValue("\(refScheme)://\(refHost)\(portSuffix)", forHTTPHeaderField: "Origin")
        }
        if let range = requestHeaders["range"] {
            upstreamReq.setValue(range, forHTTPHeaderField: "Range")
        }

        let task = upstreamSession.dataTask(with: upstreamReq) { [weak self] data, response, error in
            guard let self = self else {
                connection.cancel()
                return
            }

            if let error = error {
                self.sendTextResponse(connection: connection, status: "502 Bad Gateway", body: "Upstream error: \(error.localizedDescription)")
                return
            }

            guard let httpResp = response as? HTTPURLResponse else {
                self.sendTextResponse(connection: connection, status: "502 Bad Gateway", body: "Invalid upstream response")
                return
            }

            let statusCode = httpResp.statusCode
            let payload = data ?? Data()
            let effectiveURL = httpResp.url ?? targetURL
            let upstreamCT = (httpResp.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            let looksLikeM3U8 = (typeParam == "m3u8")
                || upstreamCT.contains("mpegurl")
                || (payload.count < 512_000 && (String(data: payload.prefix(64), encoding: .utf8)?.contains("#EXTM3U") == true))

            if statusCode >= 400 {
                let errText = String(data: payload, encoding: .utf8) ?? "HTTP \(statusCode)"
                self.sendTextResponse(connection: connection, status: "\(statusCode) Upstream Error", body: errText)
                return
            }

            if looksLikeM3U8,
               let textBody = String(data: payload, encoding: .utf8),
               textBody.contains("#EXTM3U"),
               let proxyBase = self.currentBaseURL {
                let rewritten = M3U8Rewriter.rewritePlaylist(
                    textBody,
                    effectiveURL: effectiveURL,
                    referer: referer,
                    proxyBaseURL: proxyBase
                )
                let outData = Data(rewritten.utf8)
                self.sendBinaryResponse(
                    connection: connection,
                    statusLine: "200 OK",
                    contentType: "application/vnd.apple.mpegurl",
                    body: method == "HEAD" ? Data() : outData,
                    reportedLength: outData.count,
                    extraHeaders: [
                        "Cache-Control": "no-store, no-cache, must-revalidate",
                        "Access-Control-Allow-Origin": "*"
                    ]
                )
                return
            }

            let statusLine = statusCode == 206 ? "206 Partial Content" : "200 OK"
            let mediaCT: String
            if !upstreamCT.isEmpty && !upstreamCT.contains("text/plain") {
                mediaCT = httpResp.value(forHTTPHeaderField: "Content-Type") ?? "video/mp2t"
            } else {
                mediaCT = "video/mp2t"
            }

            var extraHeaders: [String: String] = [
                "Accept-Ranges": "bytes",
                "Cache-Control": "public, max-age=3600",
                "Access-Control-Allow-Origin": "*"
            ]
            if let contentRange = httpResp.value(forHTTPHeaderField: "Content-Range") {
                extraHeaders["Content-Range"] = contentRange
            }

            let expectedLength: Int
            if method == "HEAD",
               let clStr = httpResp.value(forHTTPHeaderField: "Content-Length"),
               let clInt = Int(clStr) {
                expectedLength = clInt
            } else {
                expectedLength = payload.count
            }

            self.sendBinaryResponse(
                connection: connection,
                statusLine: statusLine,
                contentType: mediaCT,
                body: method == "HEAD" ? Data() : payload,
                reportedLength: expectedLength,
                extraHeaders: extraHeaders
            )
        }
        task.resume()
    }

    private func sendTextResponse(connection: NWConnection, status: String, body: String) {
        let data = Data(body.utf8)
        sendBinaryResponse(
            connection: connection,
            statusLine: status,
            contentType: "text/plain; charset=utf-8",
            body: data,
            reportedLength: data.count,
            extraHeaders: ["Cache-Control": "no-store"]
        )
    }

    private func sendBinaryResponse(
        connection: NWConnection,
        statusLine: String,
        contentType: String,
        body: Data,
        reportedLength: Int,
        extraHeaders: [String: String] = [:]
    ) {
        var headerLines = [
            "HTTP/1.1 \(statusLine)",
            "Content-Type: \(contentType)",
            "Content-Length: \(reportedLength)",
            "Connection: close"
        ]
        for (k, v) in extraHeaders {
            headerLines.append("\(k): \(v)")
        }
        let headerString = headerLines.joined(separator: "\r\n") + "\r\n\r\n"
        var responseData = Data(headerString.utf8)
        if !body.isEmpty {
            responseData.append(body)
        }

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
