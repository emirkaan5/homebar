import Foundation
import Core
#if canImport(FoundationNetworking)
// So that the session and command logic can be built and tested off-Darwin too.
import FoundationNetworking
#endif

/// One request to Amazon. `AmazonAPI` builds these; a transport sends them.
public struct AmazonRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?

    public init(url: URL, method: String, headers: [String: String] = [:], body: Data? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public struct AmazonReply: Sendable {
    public var data: Data
    public var status: Int

    public init(data: Data, status: Int) {
        self.data = data
        self.status = status
    }
}

/// Sends a request and returns the reply. The app uses `URLSessionHTTP`; the tests
/// use a fake, so that the requests this app builds can be checked without a network.
public protocol AmazonHTTP: Sendable {
    func send(_ request: AmazonRequest) async throws -> AmazonReply
}

/// The real transport. It keeps no cookies of its own: the session travels in the
/// headers that `AmazonAPI` builds, so only one place ever holds it.
public struct URLSessionHTTP: AmazonHTTP {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: AmazonRequest) async throws -> AmazonReply {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            return AmazonReply(data: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw HomeProviderError.offline
        }
    }
}
