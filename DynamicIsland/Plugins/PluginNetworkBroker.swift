import Darwin
import Foundation

nonisolated enum PluginNetworkError: Error, Equatable, LocalizedError, Sendable {
    case invalidArguments, policyDenied, quotaExceeded, timeout, responseTooLarge
    case invalidResponse, transportFailed, inactiveExecution, permissionRevoked

    var code: String {
        switch self {
        case .invalidArguments: "invalidArguments"
        case .policyDenied: "networkPolicyDenied"
        case .quotaExceeded: "quotaExceeded"
        case .timeout: "networkTimeout"
        case .responseTooLarge: "networkResponseTooLarge"
        case .invalidResponse: "networkInvalidResponse"
        case .transportFailed: "networkTransportFailed"
        case .inactiveExecution: "inactiveExecution"
        case .permissionRevoked: "permissionRevoked"
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidArguments: "Invalid network request arguments."
        case .policyDenied: "The Host network policy rejected this request."
        case .quotaExceeded: "The Host network concurrency limit was reached."
        case .timeout: "The network request timed out."
        case .responseTooLarge: "The network response exceeded the Host size limit."
        case .invalidResponse: "The network response could not be decoded."
        case .transportFailed: "The network request failed."
        case .inactiveExecution: "This plugin execution is inactive."
        case .permissionRevoked: "The network authorization is no longer valid."
        }
    }
}

nonisolated struct PluginNetworkRequest: Sendable {
    let url: URL
    let method: String
    let headers: [String: String]
    let timeoutSeconds: TimeInterval

    static func parse(_ json: PluginBridgeJSON) throws -> Self {
        guard case .object(let fields) = json, fields["url"] != nil,
              Set(fields.keys).isSubset(of: ["url", "method", "headers", "timeoutMs"]),
              case .string(let source) = fields["url"], !source.isEmpty,
              source.utf8.count <= 2_048, !containsControl(source), let url = URL(string: source),
              url.scheme != nil, url.host != nil
        else { throw PluginNetworkError.invalidArguments }
        var method = "GET", headers: [String: String] = [:], milliseconds = 10_000.0
        if let value = fields["method"] {
            guard case .string(let text) = value else { throw PluginNetworkError.invalidArguments }
            method = text.uppercased()
        }
        if let value = fields["headers"] {
            guard case .object(let values) = value else { throw PluginNetworkError.invalidArguments }
            for (name, value) in values {
                guard case .string(let text) = value else { throw PluginNetworkError.invalidArguments }
                headers[name] = text
            }
        }
        if let value = fields["timeoutMs"] {
            guard case .number(let number) = value, number.isFinite, number.rounded() == number,
                  (100...30_000).contains(number) else { throw PluginNetworkError.invalidArguments }
            milliseconds = number
        }
        let request = Self(url: url, method: method, headers: headers, timeoutSeconds: milliseconds / 1_000)
        try request.validate()
        return request
    }

    fileprivate func validate() throws {
        guard url.absoluteString.utf8.count <= 2_048, method == "GET" || method == "HEAD",
              timeoutSeconds.isFinite, (0.1...30).contains(timeoutSeconds), headers.count <= 16
        else { throw PluginNetworkError.invalidArguments }
        let tokens = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var names = Set<String>(), total = 0
        for (name, value) in headers {
            let lower = name.lowercased()
            guard !name.isEmpty, name.utf8.count <= 64, name.unicodeScalars.allSatisfy({ tokens.contains($0) }),
                  value.utf8.count <= 1_024, !Self.containsControl(value), names.insert(lower).inserted
            else { throw PluginNetworkError.invalidArguments }
            guard !Self.forbiddenHeaders.contains(lower), !lower.hasPrefix("proxy-"),
                  !lower.hasPrefix("x-forwarded-") else { throw PluginNetworkError.policyDenied }
            total += name.utf8.count + value.utf8.count
        }
        guard total <= 4_096 else { throw PluginNetworkError.invalidArguments }
    }

    fileprivate static func containsControl(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static let forbiddenHeaders: Set<String> = [
        "host", "cookie", "cookie2", "connection", "keep-alive", "te", "trailer",
        "transfer-encoding", "upgrade", "content-length", "forwarded"
    ]
}

nonisolated struct PluginNetworkResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: String
}

/// Final delivery shares a short synchronous gate with Runtime invalidation.
/// Cancellation handlers execute outside the gate and must not wait for MainActor.
nonisolated final class PluginNetworkAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var cancellations: [UUID: @Sendable () -> Void] = [:]

    func registerCancellation(_ handler: @escaping @Sendable () -> Void) throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        guard active else { throw PluginNetworkError.inactiveExecution }
        let id = UUID(); cancellations[id] = handler
        return id
    }

    func unregister(_ id: UUID) {
        lock.lock(); cancellations.removeValue(forKey: id); lock.unlock()
    }

    func revoke() {
        lock.lock(); active = false
        let handlers = Array(cancellations.values); cancellations.removeAll(); lock.unlock()
        handlers.forEach { $0() }
    }

    func perform<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard active else { throw PluginNetworkError.inactiveExecution }
        return try body()
    }
}

/// DNS validation is a preflight, not address pinning. The narrow Host allowlist
/// is part of the policy; URLSession may resolve the host again for transport.
public nonisolated final class PluginNetworkBroker: @unchecked Sendable {
    public typealias Resolver = @Sendable (_ host: String) throws -> [String]
    static let maximumResponseBytes = 65_536
    private let allowedHosts: Set<String>
    private let configuration: URLSessionConfiguration
    private let resolver: Resolver
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var total = 0
    fileprivate static let workQueue = DispatchQueue(label: "DynamicIsland.PluginNetwork", attributes: .concurrent)

    public init(allowedHosts: Set<String> = ["api.github.com"], configuration: URLSessionConfiguration? = nil,
                resolver: Resolver? = nil) {
        self.allowedHosts = Set(allowedHosts.compactMap { try? Self.normalizedHost($0) })
        self.configuration = .ephemeral
        self.configuration.protocolClasses = configuration?.protocolClasses
        self.resolver = resolver ?? Self.resolve
    }

    /// Admission and quota errors are synchronous. Completion executes once on
    /// a background queue and must remain short; it may enqueue a worker reply.
    func start(request: PluginNetworkRequest, pluginID: String, authorization: PluginPermissionLease,
               admission: PluginNetworkAdmission,
               completion: @escaping @Sendable (Result<PluginNetworkResponse, PluginNetworkError>) -> Void) throws {
        try request.validate()
        guard var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", components.user == nil, components.password == nil,
              components.port == nil || components.port == 443, let source = components.host
        else { throw PluginNetworkError.policyDenied }
        let host = try Self.normalizedHost(source)
        guard allowedHosts.contains(host) else { throw PluginNetworkError.policyDenied }
        components.host = host
        guard let url = components.url else { throw PluginNetworkError.policyDenied }
        do {
            try admission.perform {
                try authorization.perform(pluginID: pluginID, permission: .network) {
                    lock.lock(); defer { lock.unlock() }
                    guard total < 8, counts[pluginID, default: 0] < 2 else { throw PluginNetworkError.quotaExceeded }
                    total += 1; counts[pluginID, default: 0] += 1
                }
            }
        } catch { throw PluginNetworkOperation.map(error) }
        let operation = PluginNetworkOperation(request: request, url: url, host: host, pluginID: pluginID,
            authorization: authorization, admission: admission, configuration: configuration, resolver: resolver,
            completion: completion, release: { [self] in
                lock.lock(); total -= 1
                if counts[pluginID, default: 0] <= 1 { counts.removeValue(forKey: pluginID) }
                else { counts[pluginID, default: 0] -= 1 }
                lock.unlock()
            })
        do {
            let id = try admission.registerCancellation { operation.finish(.failure(.inactiveExecution)) }
            operation.setCancellationID(id)
        } catch {
            operation.abandon()
            throw PluginNetworkError.inactiveExecution
        }
        operation.start()
    }

    private static func normalizedHost(_ source: String) throws -> String {
        var host = source.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        var ipv4 = in_addr()
        guard inet_aton(host, &ipv4) == 0, !host.contains(":"), !host.contains("%"),
              host.utf8.count <= 253, host != "localhost", !host.hasSuffix(".localhost"), !host.hasSuffix(".local")
        else { throw PluginNetworkError.policyDenied }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ label in
            (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-" &&
                label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }) else { throw PluginNetworkError.policyDenied }
        return host
    }

    static func isPublicAddress(_ source: String) -> Bool {
        let pieces = source.split(separator: ".", omittingEmptySubsequences: false)
        if pieces.count == 4, pieces.allSatisfy({ !$0.isEmpty && ($0.count == 1 || $0.first != "0") &&
            $0.utf8.allSatisfy { (48...57).contains($0) } }),
           let a = UInt8(pieces[0]), let b = UInt8(pieces[1]), let c = UInt8(pieces[2]), UInt8(pieces[3]) != nil {
            return !(a == 0 || a == 10 || a == 127 || a >= 224 || (a == 100 && (64...127).contains(b)) ||
                (a == 169 && b == 254) || (a == 172 && (16...31).contains(b)) ||
                (a == 192 && (b == 168 || (b == 0 && (c == 0 || c == 2)) || (b == 88 && c == 99))) ||
                (a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100))) || (a == 203 && b == 0 && c == 113))
        }
        var address = in6_addr()
        guard inet_pton(AF_INET6, source, &address) == 1 else { return false }
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 255, bytes[11] == 255 {
            return isPublicAddress(bytes[12...15].map(String.init).joined(separator: "."))
        }
        guard bytes[0] & 0xe0 == 0x20 else { return false }
        if bytes[0] == 0x20 && bytes[1] == 0x01 {
            if bytes[2] < 2 || (bytes[2] == 0x0d && bytes[3] == 0xb8) { return false }
        }
        return !(bytes[0] == 0x20 && bytes[1] == 0x02) &&
            !(bytes[0] == 0x3f && bytes[1] == 0xff && bytes[2] & 0xf0 == 0)
    }

    private static func resolve(_ host: String) throws -> [String] {
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        var first: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &first) == 0, let first else { throw PluginNetworkError.transportFailed }
        defer { freeaddrinfo(first) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first, values: [String] = []
        while let item = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(item.pointee.ai_addr, item.pointee.ai_addrlen, &buffer,
                              socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0
            else { throw PluginNetworkError.transportFailed }
            values.append(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            cursor = item.pointee.ai_next
        }
        return values
    }
}

private nonisolated final class PluginNetworkOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let request: PluginNetworkRequest, url: URL, host: String, pluginID: String
    private let authorization: PluginPermissionLease, admission: PluginNetworkAdmission
    private let configuration: URLSessionConfiguration, resolver: PluginNetworkBroker.Resolver
    private let completion: @Sendable (Result<PluginNetworkResponse, PluginNetworkError>) -> Void
    private let release: @Sendable () -> Void
    private var done = false, dnsPending = false, reservationReleased = false, data = Data()
    private var response: HTTPURLResponse?, session: URLSession?, task: URLSessionDataTask?
    private var deadline: DispatchWorkItem?, cancellationID: UUID?
    private var permissionObservation: PluginPermissionObservation?

    init(request: PluginNetworkRequest, url: URL, host: String, pluginID: String,
         authorization: PluginPermissionLease, admission: PluginNetworkAdmission,
         configuration: URLSessionConfiguration, resolver: @escaping PluginNetworkBroker.Resolver,
         completion: @escaping @Sendable (Result<PluginNetworkResponse, PluginNetworkError>) -> Void,
         release: @escaping @Sendable () -> Void) {
        self.request = request; self.url = url; self.host = host; self.pluginID = pluginID
        self.authorization = authorization; self.admission = admission
        self.configuration = configuration; self.resolver = resolver; self.completion = completion; self.release = release
    }

    func setCancellationID(_ id: UUID) {
        lock.lock(); let finished = done
        if !finished { cancellationID = id }; lock.unlock()
        if finished { admission.unregister(id) }
    }

    func start() {
        let observation = authorization.observeRevocation { [weak self] in self?.finish(.failure(.permissionRevoked)) }
        lock.lock(); let finished = done
        if !finished { permissionObservation = observation }; lock.unlock()
        if finished { observation.cancel(); return }
        let timer = DispatchWorkItem { [weak self] in self?.finish(.failure(.timeout)) }
        lock.lock(); guard !done else { lock.unlock(); return }; deadline = timer; lock.unlock()
        PluginNetworkBroker.workQueue.asyncAfter(deadline: .now() + request.timeoutSeconds, execute: timer)
        lock.lock(); guard !done else { lock.unlock(); return }; dnsPending = true; lock.unlock()
        PluginNetworkBroker.workQueue.async { [self] in
            defer { dnsFinished() }
            lock.lock(); let finished = done; lock.unlock()
            guard !finished else { return }
            do {
                try admitted {}
                let addresses = try resolver(host)
                guard !addresses.isEmpty, addresses.allSatisfy(PluginNetworkBroker.isPublicAddress)
                else { throw PluginNetworkError.policyDenied }
                try beginTransport()
            } catch { finish(.failure(Self.map(error))) }
        }
    }

    private func beginTransport() throws {
        let config = configuration.copy() as! URLSessionConfiguration
        config.urlCache = nil; config.urlCredentialStorage = nil; config.httpCookieStorage = nil
        config.httpShouldSetCookies = false; config.httpCookieAcceptPolicy = .never; config.httpAdditionalHeaders = nil
        config.connectionProxyDictionary = [:]; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = request.timeoutSeconds; config.timeoutIntervalForResource = request.timeoutSeconds
        config.waitsForConnectivity = false
        var native = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: request.timeoutSeconds)
        native.httpMethod = request.method; native.allHTTPHeaderFields = request.headers; native.httpShouldHandleCookies = false
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: native)
        do {
            try admitted {
                lock.lock(); defer { lock.unlock() }
                guard !done else { return }
                self.session = session; self.task = task; task.resume()
            }
        } catch { session.invalidateAndCancel(); throw error }
        lock.lock(); let finished = done; lock.unlock()
        if finished { session.invalidateAndCancel() }
    }

    private func admitted<T>(_ body: () throws -> T) throws -> T {
        try admission.perform { try authorization.perform(pluginID: pluginID, permission: .network, body) }
    }

    /// Cleanup is claimed once; late DNS and delegate callbacks cannot deliver again.
    func finish(_ result: Result<PluginNetworkResponse, PluginNetworkError>) {
        guard let state = claim() else { return }
        cleanup(state)
        PluginNetworkBroker.workQueue.async { [self] in
            do { try admitted { completion(result) } }
            catch { completion(.failure(Self.map(error))) }
        }
    }

    func abandon() { if let state = claim() { cleanup(state) } }

    private typealias Cleanup = (URLSession?, URLSessionDataTask?, DispatchWorkItem?, UUID?, PluginPermissionObservation?)
    private func claim() -> Cleanup? {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return nil }; done = true
        let state = (session, task, deadline, cancellationID, permissionObservation)
        session = nil; task = nil; deadline = nil; cancellationID = nil; permissionObservation = nil; data.removeAll()
        return state
    }

    private func cleanup(_ state: Cleanup) {
        state.4?.cancel(); state.2?.cancel(); state.1?.cancel(); state.0?.invalidateAndCancel()
        if let id = state.3 { admission.unregister(id) }
        releaseReservationIfIdle()
    }

    /// A blocked system resolver remains part of the concurrency reservation
    /// even after its Promise deadline; it cannot accumulate extra DNS workers.
    private func dnsFinished() {
        lock.lock(); dnsPending = false; lock.unlock()
        releaseReservationIfIdle()
    }

    private func releaseReservationIfIdle() {
        lock.lock()
        let shouldRelease = done && !dnsPending && !reservationReleased
        if shouldRelease { reservationReleased = true }; lock.unlock()
        if shouldRelease { release() }
    }

    fileprivate static func map(_ error: Error) -> PluginNetworkError {
        if let error = error as? PluginNetworkError { return error }
        if error is PluginPermissionError { return .permissionRevoked }
        if let error = error as? URLError, error.code == .timedOut { return .timeout }
        return .transportFailed
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        do {
            try admitted {}
            guard let response = response as? HTTPURLResponse else { throw PluginNetworkError.invalidResponse }
            guard !(300...399).contains(response.statusCode) else { throw PluginNetworkError.policyDenied }
            guard response.expectedContentLength <= PluginNetworkBroker.maximumResponseBytes
            else { throw PluginNetworkError.responseTooLarge }
            lock.lock(); let finished = done; if !finished { self.response = response }; lock.unlock()
            completionHandler(finished ? .cancel : .allow)
        } catch { completionHandler(.cancel); finish(.failure(Self.map(error))) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        do {
            try admitted {
                lock.lock(); defer { lock.unlock() }
                guard !done else { return }
                guard chunk.count <= PluginNetworkBroker.maximumResponseBytes - data.count
                else { throw PluginNetworkError.responseTooLarge }
                data.append(chunk)
            }
        } catch { finish(.failure(Self.map(error))) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(Self.map(error))); return }
        lock.lock(); let response = self.response, bytes = data; let finished = done; lock.unlock()
        guard !finished else { return }
        guard let response, let body = String(data: bytes, encoding: .utf8) else { finish(.failure(.invalidResponse)); return }
        let hidden: Set<String> = ["location", "set-cookie", "set-cookie2", "cookie", "authorization",
            "proxy-authorization", "www-authenticate", "proxy-authenticate", "authentication-info", "proxy-authentication-info"]
        var headers: [String: String] = [:], headerBytes = 0
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String, !hidden.contains(name.lowercased()) else { continue }
            let text = String(describing: value)
            if !PluginNetworkRequest.containsControl(name), !PluginNetworkRequest.containsControl(text) {
                headerBytes += name.utf8.count + text.utf8.count
                guard headerBytes <= 4_096 else { finish(.failure(.responseTooLarge)); return }
                headers[name] = text
            }
        }
        finish(.success(PluginNetworkResponse(status: response.statusCode, headers: headers, body: body)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil); finish(.failure(.policyDenied))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else { completionHandler(.cancelAuthenticationChallenge, nil); finish(.failure(.policyDenied)) }
    }
}
