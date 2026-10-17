import Foundation

/// A per-test HTTP stub: an ephemeral `URLSession` whose requests are answered by this test's handler and recorded.
/// Each stub's session carries its own routing token, so parallel tests never see each other's traffic.
final class TestHTTPStub: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data

        func header(_ name: String) -> String? {
            headers.first { $0.key.lowercased() == name.lowercased() }?.value
        }
    }

    enum Reply: Sendable {
        case respond(status: Int, headers: [String: String] = [:], body: Data)
        /// The request never gets an answer (it ends only when cancelled).
        case never
        case fail(URLError.Code)

        static func json(_ status: Int, _ text: String, headers: [String: String] = [:]) -> Reply {
            .respond(status: status, headers: headers, body: Data(text.utf8))
        }
    }

    static let routeHeader = "X-Argus-Test-Route"

    let session: URLSession
    let token = UUID().uuidString
    let handler: @Sendable (Request) async -> Reply
    private let lock = NSLock()
    private var recorded: [Request] = []

    init(_ handler: @escaping @Sendable (Request) async -> Reply) {
        self.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        config.httpAdditionalHeaders = [Self.routeHeader: token]
        session = URLSession(configuration: config)
        StubRegistry.shared.add(self)
    }

    deinit {
        // The session stays valid: work a test left running (a poller batch after `stop()`) may still send, and an
        // unregistered token makes the request fail instead of trapping on an invalidated session.
        StubRegistry.shared.remove(token)
    }

    var requests: [Request] { lock.withLock { recorded } }

    func record(_ request: Request) {
        lock.withLock { recorded.append(request) }
    }
}

final class StubRegistry: @unchecked Sendable {
    static let shared = StubRegistry()
    private let lock = NSLock()
    private var stubs: [String: Weak] = [:]

    private struct Weak { weak var stub: TestHTTPStub? }

    func add(_ stub: TestHTTPStub) { lock.withLock { stubs[stub.token] = Weak(stub: stub) } }
    func remove(_ token: String) { lock.withLock { _ = stubs.removeValue(forKey: token) } }
    func stub(_ token: String) -> TestHTTPStub? { lock.withLock { stubs[token]?.stub } }
}

struct Unchecked<T>: @unchecked Sendable { let value: T }

final class StubProtocol: URLProtocol {
    private let lock = NSLock()
    private var work: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let token = request.value(forHTTPHeaderField: TestHTTPStub.routeHeader), let stub = StubRegistry.shared.stub(token) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        var headers = request.allHTTPHeaderFields ?? [:]
        headers.removeValue(forKey: TestHTTPStub.routeHeader)
        let recorded = TestHTTPStub.Request(method: request.httpMethod ?? "GET", url: request.url!, headers: headers, body: Self.body(of: request))
        stub.record(recorded)
        let me = Unchecked(value: self)   // URLProtocol is not Sendable; the client is called from this one task
        let task = Task {
            let reply = await stub.handler(recorded)
            guard !Task.isCancelled else { return }
            me.value.deliver(reply)
        }
        lock.withLock { work = task }
    }

    override func stopLoading() {
        lock.withLock { work?.cancel() }
    }

    private func deliver(_ reply: TestHTTPStub.Reply) {
        switch reply {
        case .respond(let status, let headers, let body):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .never:
            break
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
