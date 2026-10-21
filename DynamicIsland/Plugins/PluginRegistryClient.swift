import Foundation

/// User-initiated discovery/download only. It returns an ordinary Installer
/// review; callers must still present it for explicit confirmation.
public actor PluginRegistryClient {
    private let transport: PluginRegistryTransport
    private var busy = false

    public init() { transport = PluginRegistryTransport() }
    init(protocolClasses: [AnyClass]) { transport = PluginRegistryTransport(protocolClasses: protocolClasses) }

    public func loadCatalog(from url: URL) async throws -> PluginRegistryCatalog {
        guard !busy else { throw PluginRegistryError.busy }
        try PluginRegistryURLPolicy.catalog(url)
        busy = true
        defer { busy = false }
        let data = try await transport.fetch(url: url, kind: .catalog)
        try Task.checkCancellation()
        return try PluginRegistryCatalog.decode(data)
    }

    public func prepareDownload(_ entry: PluginRegistryEntry, installer: PluginInstaller) async throws -> PluginInstallReview {
        guard !busy else { throw PluginRegistryError.busy }
        busy = true
        defer { busy = false }
        let data = try await transport.fetch(url: entry.download, kind: .archive)
        try Task.checkCancellation()
        // Hash and unzip share the immutable buffer in the Installer. There
        // is no intermediate downloaded path that can be swapped or leaked.
        return try await installer.prepare(archiveData: data, registryEntry: entry)
    }
}

nonisolated enum PluginRegistryFetchKind: Sendable {
    case catalog, archive
    var maximumBytes: Int {
        switch self {
        case .catalog: PluginRegistryCatalog.maximumBytes
        case .archive: PluginPackageArchiveExtractor.maximumArchiveBytes
        }
    }
}

/// URLSession's incremental delegate bounds memory before retaining bytes,
/// including responses with no or dishonest Content-Length.
nonisolated struct PluginRegistryTransport: @unchecked Sendable {
    private let protocolClasses: [AnyClass]?
    init(protocolClasses: [AnyClass]? = nil) { self.protocolClasses = protocolClasses }

    func fetch(url: URL, kind: PluginRegistryFetchKind) async throws -> Data {
        let operation = PluginRegistryTransfer(url: url, kind: kind, protocolClasses: protocolClasses)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await operation.start()
        } onCancel: { operation.cancel() }
    }
}

nonisolated final class PluginRegistryTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private let kind: PluginRegistryFetchKind
    private let protocolClasses: [AnyClass]?
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var finished = false
    private var buffer = Data()
    private var acceptedResponse = false
    private var redirects = 0

    init(url: URL, kind: PluginRegistryFetchKind, protocolClasses: [AnyClass]?) {
        self.url = url; self.kind = kind; self.protocolClasses = protocolClasses
    }

    func start() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let task: URLSessionDataTask? = lock.withLock {
                guard !finished else { return nil }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = protocolClasses
                configuration.httpCookieStorage = nil
                configuration.httpShouldSetCookies = false
                configuration.urlCredentialStorage = nil
                configuration.urlCache = nil
                configuration.timeoutIntervalForRequest = 20
                configuration.timeoutIntervalForResource = 60
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                self.session = session
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
                request.httpMethod = "GET"
                request.httpShouldHandleCookies = false
                request.setValue(kind == .catalog ? "application/json" : "application/octet-stream", forHTTPHeaderField: "Accept")
                let task = session.dataTask(with: request)
                self.task = task
                return task
            }
            if let task { task.resume() }
            else { continuation.resume(throwing: PluginRegistryError.cancelled) }
        }
    }

    func cancel() { finish(.failure(PluginRegistryError.cancelled)) }

    private func finish(_ result: Result<Data, Error>) {
        let state = lock.withLock { () -> (CheckedContinuation<Data, Error>?, URLSession?, URLSessionDataTask?)? in
            guard !finished else { return nil }
            finished = true
            let state = (continuation, session, task)
            continuation = nil; session = nil; task = nil; buffer = Data()
            return state
        }
        guard let state else { return }
        state.2?.cancel()
        state.1?.invalidateAndCancel()
        state.0?.resume(with: result)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            completionHandler(.cancel); finish(.failure(PluginRegistryError.httpStatus)); return
        }
        guard response.expectedContentLength <= kind.maximumBytes else {
            completionHandler(.cancel); finish(.failure(PluginRegistryError.tooLarge)); return
        }
        let accepted = lock.withLock { () -> Bool in
            guard !finished else { return false }
            acceptedResponse = true
            return true
        }
        completionHandler(accepted ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let tooLarge = lock.withLock { () -> Bool in
            guard !finished else { return false }
            guard acceptedResponse, data.count <= kind.maximumBytes - buffer.count else { return true }
            buffer.append(data)
            return false
        }
        if tooLarge { finish(.failure(PluginRegistryError.tooLarge)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { finish(.failure(PluginRegistryError.transportFailed)); return }
        let data = lock.withLock { acceptedResponse && !finished ? buffer : nil }
        if let data { finish(.success(data)) }
        else { finish(.failure(PluginRegistryError.transportFailed)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        let allowed = lock.withLock { () -> Bool in
            guard !finished, kind == .archive, redirects < 3, let target = request.url,
                  (try? PluginRegistryURLPolicy.redirect(target)) != nil else { return false }
            redirects += 1
            return true
        }
        guard allowed, let target = request.url else {
            completionHandler(nil); finish(.failure(PluginRegistryError.redirectRejected)); return
        }
        // Rebuild instead of forwarding inherited credentials or headers.
        var clean = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData)
        clean.httpMethod = "GET"
        clean.httpShouldHandleCookies = false
        clean.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        completionHandler(clean)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}
