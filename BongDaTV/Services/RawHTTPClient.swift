import Foundation
import Network

struct RawHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
    let finalURL: URL
}

enum RawHTTPClientError: LocalizedError {
    case invalidURL
    case emptyResponse
    case malformedHTTPResponse
    case tooManyRedirects
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "URL không hợp lệ."
        case .emptyResponse:
            return "Máy chủ đóng kết nối mà không trả dữ liệu."
        case .malformedHTTPResponse:
            return "Phản hồi HTTP không hợp lệ."
        case .tooManyRedirects:
            return "Chuyển hướng quá nhiều lần."
        case .timedOut:
            return "Hết thời gian chờ kết nối TCP."
        }
    }
}

enum RawHTTPClient {
    static let defaultUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    static func isATSError(_ error: Error) -> Bool {
        if let urlError = error as? URLError,
           urlError.code == .appTransportSecurityRequiresSecureConnection {
            return true
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == -1022 {
            return true
        }
        return nsError.localizedDescription.localizedCaseInsensitiveContains("App Transport Security")
    }

    static func request(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        timeout: TimeInterval = 12,
        redirectDepth: Int = 0
    ) async throws -> RawHTTPResponse {
        guard redirectDepth <= 5 else {
            throw RawHTTPClientError.tooManyRedirects
        }

        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "https" {
            return try await performHTTPSRequest(url: url, method: method, headers: headers, timeout: timeout)
        }

        guard scheme == "http", let host = url.host, !host.isEmpty else {
            throw RawHTTPClientError.invalidURL
        }

        let rawData = try await performSingleTCPRequest(url: url, host: host, method: method, headers: headers, timeout: timeout)
        let parsed = try parseHTTPResponse(rawData, requestURL: url)

        if [301, 302, 303, 307, 308].contains(parsed.statusCode),
           let location = parsed.headers["location"],
           let nextURL = URL(string: location, relativeTo: url)?.absoluteURL {
            let nextMethod = (parsed.statusCode == 303 && method.uppercased() != "HEAD") ? "GET" : method
            return try await request(
                url: nextURL,
                method: nextMethod,
                headers: headers,
                timeout: timeout,
                redirectDepth: redirectDepth + 1
            )
        }

        return parsed
    }

    static func parseHTTPResponse(_ raw: Data, requestURL: URL) throws -> RawHTTPResponse {
        let separator = Data("\r\n\r\n".utf8)
        guard let sepRange = raw.range(of: separator) else {
            if raw.isEmpty {
                throw RawHTTPClientError.emptyResponse
            }
            throw RawHTTPClientError.malformedHTTPResponse
        }

        let headerData = raw.subdata(in: 0..<sepRange.lowerBound)
        let rawBody = raw.subdata(in: sepRange.upperBound..<raw.count)

        guard let headerString = String(data: headerData, encoding: .utf8)
            ?? String(data: headerData, encoding: .isoLatin1) else {
            throw RawHTTPClientError.malformedHTTPResponse
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw RawHTTPClientError.malformedHTTPResponse
        }

        let statusParts = statusLine.split(separator: " ", omittingEmptySubsequences: true)
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
            throw RawHTTPClientError.malformedHTTPResponse
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        let isChunked = headers["transfer-encoding"]?.lowercased().contains("chunked") == true
        let decodedBody = isChunked ? decodeChunked(rawBody) : rawBody

        return RawHTTPResponse(
            statusCode: statusCode,
            headers: headers,
            body: decodedBody,
            finalURL: requestURL
        )
    }

    static func decodeChunked(_ data: Data) -> Data {
        var result = Data()
        let crlf = Data("\r\n".utf8)
        var offset = 0

        while offset < data.count {
            guard let lineEnd = data.range(of: crlf, options: [], in: offset..<data.count) else {
                break
            }
            let sizeData = data.subdata(in: offset..<lineEnd.lowerBound)
            guard let sizeLine = String(data: sizeData, encoding: .ascii) else {
                break
            }
            let hexPart = sizeLine.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            guard let chunkSize = Int(hexPart, radix: 16) else {
                break
            }

            offset = lineEnd.upperBound
            if chunkSize == 0 {
                break
            }

            let available = data.count - offset
            let toCopy = min(chunkSize, max(0, available))
            if toCopy > 0 {
                result.append(data.subdata(in: offset..<(offset + toCopy)))
            }
            offset += toCopy
            if offset + 2 <= data.count && data[offset] == 0x0D && data[offset + 1] == 0x0A {
                offset += 2
            }
        }

        return result
    }

    private static func performHTTPSRequest(
        url: URL,
        method: String,
        headers: [String: String],
        timeout: TimeInterval
    ) async throws -> RawHTTPResponse {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw RawHTTPClientError.malformedHTTPResponse
        }
        var lowered: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            lowered[String(describing: k).lowercased()] = String(describing: v)
        }
        return RawHTTPResponse(
            statusCode: http.statusCode,
            headers: lowered,
            body: data,
            finalURL: http.url ?? url
        )
    }

    private static func performSingleTCPRequest(
        url: URL,
        host: String,
        method: String,
        headers: [String: String],
        timeout: TimeInterval
    ) async throws -> Data {
        let portValue = UInt16(url.port ?? 80)
        guard let nwPort = NWEndpoint.Port(rawValue: portValue) else {
            throw RawHTTPClientError.invalidURL
        }

        let hostHeader: String
        if let explicitPort = url.port {
            hostHeader = "\(host):\(explicitPort)"
        } else {
            hostHeader = host
        }

        var pathWithQuery = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty {
            pathWithQuery += "?\(query)"
        }

        var headerLines = [
            "\(method.uppercased()) \(pathWithQuery) HTTP/1.1",
            "Host: \(hostHeader)",
            "Accept: */*",
            "Accept-Encoding: identity",
            "Connection: close"
        ]

        var hasUserAgent = false
        for (k, v) in headers {
            if k.lowercased() == "host" || k.lowercased() == "connection" || k.lowercased() == "accept-encoding" {
                continue
            }
            if k.lowercased() == "user-agent" {
                hasUserAgent = true
            }
            headerLines.append("\(k): \(v)")
        }
        if !hasUserAgent {
            headerLines.append("User-Agent: \(defaultUserAgent)")
        }

        let requestData = Data((headerLines.joined(separator: "\r\n") + "\r\n\r\n").utf8)

        return try await withCheckedThrowingContinuation { continuation in
            let runner = TCPRequestRunner(
                host: host,
                port: nwPort,
                method: method.uppercased(),
                requestData: requestData,
                timeout: timeout,
                continuation: continuation
            )
            runner.start()
        }
    }
}

private final class TCPRequestRunner: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let method: String
    private let requestData: Data
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<Data, Error>?
    private var buffer = Data()
    private var finished = false
    private var timeoutWorkItem: DispatchWorkItem?
    private var headerParsed = false
    private var headerEndOffset = 0
    private var expectedContentLength: Int?
    private var isChunked = false
    private var selfRetain: TCPRequestRunner?

    init(
        host: String,
        port: NWEndpoint.Port,
        method: String,
        requestData: Data,
        timeout: TimeInterval,
        continuation: CheckedContinuation<Data, Error>
    ) {
        self.queue = DispatchQueue(label: "com.bongdatv.rawhttp.\(UUID().uuidString)")
        self.connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        self.method = method
        self.requestData = requestData
        self.timeout = timeout
        self.continuation = continuation
    }

    func start() {
        queue.async {
            guard !self.finished else { return }
            self.selfRetain = self

            let work = DispatchWorkItem { [weak self] in
                self?.finish(with: .failure(RawHTTPClientError.timedOut))
            }
            self.timeoutWorkItem = work
            self.queue.asyncAfter(deadline: .now() + self.timeout, execute: work)

            self.connection.stateUpdateHandler = { [weak self] state in
                guard let self = self, !self.finished else { return }
                switch state {
                case .ready:
                    self.sendRequest()
                case .failed(let error):
                    self.finish(with: .failure(error))
                case .cancelled:
                    if !self.buffer.isEmpty && self.headerParsed {
                        self.finish(with: .success(self.buffer))
                    } else {
                        self.finish(with: .failure(RawHTTPClientError.emptyResponse))
                    }
                default:
                    break
                }
            }
            self.connection.start(queue: self.queue)
        }
    }

    private func sendRequest() {
        connection.send(content: requestData, completion: .contentProcessed { [weak self] error in
            guard let self = self, !self.finished else { return }
            if let error = error {
                self.finish(with: .failure(error))
                return
            }
            self.receiveNextChunk()
        })
    }

    private func receiveNextChunk() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self, !self.finished else { return }
            if let data = data, !data.isEmpty {
                self.buffer.append(data)
            }

            if !self.headerParsed, let sep = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.headerParsed = true
                self.headerEndOffset = sep.upperBound
                let hdrData = self.buffer.subdata(in: 0..<sep.lowerBound)
                if let hdrStr = String(data: hdrData, encoding: .utf8) ?? String(data: hdrData, encoding: .isoLatin1) {
                    for line in hdrStr.components(separatedBy: "\r\n").dropFirst() {
                        if let colon = line.firstIndex(of: ":") {
                            let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                            if k == "content-length", let len = Int(v) {
                                self.expectedContentLength = len
                            } else if k == "transfer-encoding", v.lowercased().contains("chunked") {
                                self.isChunked = true
                            }
                        }
                    }
                }
            }

            if self.headerParsed {
                let bodyCount = self.buffer.count - self.headerEndOffset
                if self.method == "HEAD" {
                    self.finish(with: .success(self.buffer))
                    return
                }
                if let cl = self.expectedContentLength, bodyCount >= cl {
                    self.finish(with: .success(self.buffer))
                    return
                }
                if self.isChunked {
                    let tailSlice = self.buffer.subdata(in: self.headerEndOffset..<self.buffer.count)
                    if tailSlice == Data("0\r\n\r\n".utf8) || tailSlice.range(of: Data("\r\n0\r\n\r\n".utf8)) != nil {
                        self.finish(with: .success(self.buffer))
                        return
                    }
                }
            }

            if isComplete {
                if self.headerParsed {
                    self.finish(with: .success(self.buffer))
                } else {
                    self.finish(with: .failure(RawHTTPClientError.emptyResponse))
                }
                return
            }

            if let error = error {
                if self.headerParsed && !self.buffer.isEmpty {
                    self.finish(with: .success(self.buffer))
                } else {
                    self.finish(with: .failure(error))
                }
                return
            }

            self.receiveNextChunk()
        }
    }

    private func finish(with result: Result<Data, Error>) {
        guard !finished else { return }
        finished = true
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        let cont = continuation
        continuation = nil
        selfRetain = nil
        cont?.resume(with: result)
    }
}
