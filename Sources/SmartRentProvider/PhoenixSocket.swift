import Foundation
import Core

/// One message in the Phoenix channels v2 format:
/// `[join_ref, ref, topic, event, payload]`.
struct PhoenixMessage: Sendable, Equatable {
    var joinRef: String?
    var ref: String?
    var topic: String
    var event: String
    var payload: JSONValue

    init(joinRef: String?, ref: String?, topic: String, event: String, payload: JSONValue) {
        self.joinRef = joinRef
        self.ref = ref
        self.topic = topic
        self.event = event
        self.payload = payload
    }

    init(text: String) throws {
        guard let items = try JSONValue.parse(Data(text.utf8)).arrayValue, items.count == 5,
              let topic = items[2].stringValue, let event = items[3].stringValue else {
            throw HomeProviderError.unexpectedResponse("unknown websocket message")
        }
        self.init(joinRef: items[0].stringValue, ref: items[1].stringValue, topic: topic, event: event, payload: items[4])
    }

    func text() throws -> String {
        let array: JSONValue = [
            joinRef.map(JSONValue.string) ?? .null,
            ref.map(JSONValue.string) ?? .null,
            .string(topic),
            .string(event),
            payload,
        ]
        return String(decoding: try array.data(), as: UTF8.self)
    }
}

enum SocketEvent: Sendable {
    case state(ConnectionState)
    case message(PhoenixMessage)
    case sessionExpired
}

/// Keeps one websocket open, joins the device topics, sends heartbeats, and
/// reconnects after 1 s, 2 s, 4 s, and so on, to a maximum of 60 s.
actor PhoenixSocket {
    typealias URLProvider = @Sendable (_ forceRefresh: Bool) async throws -> URL

    nonisolated let events: AsyncStream<SocketEvent>
    private let sink: AsyncStream<SocketEvent>.Continuation
    private let session: URLSession
    private let makeURL: URLProvider
    private let topics: [String]

    private var socket: URLSessionWebSocketTask?
    private var joinRefs: [String: String] = [:]
    private var replies: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var nextRef = 0
    private var backoff: Duration = .seconds(1)
    private var forceRefresh = false
    private var skipBackoff = false
    private var loop: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?

    static let heartbeatInterval: Duration = .seconds(30)
    static let replyTimeout: Duration = .seconds(10)
    static let maximumBackoff: Duration = .seconds(60)

    private enum Failure: Error {
        case rejected(JSONValue)
        case timedOut
    }

    init(topics: [String], session: URLSession, makeURL: @escaping URLProvider) {
        self.topics = topics
        self.session = session
        self.makeURL = makeURL
        (events, sink) = AsyncStream.makeStream(of: SocketEvent.self)
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { await self.run() }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        sleeper?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        failReplies()
        sink.finish()
    }

    /// Drops the connection and connects again without waiting.
    func reconnectNow() {
        skipBackoff = true
        backoff = .seconds(1)
        socket?.cancel(with: .goingAway, reason: nil)
        sleeper?.cancel()
    }

    /// Sends a message on a joined topic. It does not wait for a reply, because
    /// the device confirms a change with an attribute update instead.
    func push(topic: String, event: String, payload: JSONValue) async throws {
        guard let socket, let joinRef = joinRefs[topic] else { throw HomeProviderError.offline }
        let message = PhoenixMessage(joinRef: joinRef, ref: makeRef(), topic: topic, event: event, payload: payload)
        try await socket.send(.string(try message.text()))
    }

    // MARK: Connection loop

    private func run() async {
        var first = true
        while !Task.isCancelled {
            sink.yield(.state(first ? .connecting : .reconnecting))
            first = false
            do {
                let url = try await makeURL(forceRefresh)
                forceRefresh = false
                let socket = session.webSocketTask(with: url)
                self.socket = socket
                socket.resume()
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await self.receive(on: socket) }
                    group.addTask {
                        try await self.joinAll()
                        await self.markLive()
                        try await self.sendHeartbeats()
                    }
                    try await group.next()
                    group.cancelAll()
                }
            } catch let error as HomeProviderError where error == .sessionExpired {
                sink.yield(.sessionExpired)
                sink.yield(.state(.offline))
                return
            } catch {
                // The connection dropped. Fall through and try again.
            }
            closeSocket()
            if Task.isCancelled { return }
            if skipBackoff {
                skipBackoff = false
                continue
            }
            let delay = backoff
            backoff = min(backoff * 2, Self.maximumBackoff)
            let sleeper = Task { _ = try? await Task.sleep(for: delay) }
            self.sleeper = sleeper
            await sleeper.value
        }
    }

    private func markLive() {
        backoff = .seconds(1)
        sink.yield(.state(.live))
    }

    private func closeSocket() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        joinRefs = [:]
        failReplies()
    }

    private func joinAll() async throws {
        for topic in topics {
            let ref = makeRef()
            joinRefs[topic] = ref
            do {
                _ = try await request(PhoenixMessage(joinRef: ref, ref: ref, topic: topic, event: "phx_join", payload: [:]))
            } catch Failure.rejected(let response) {
                let reason = response["reason"]?.stringValue?.lowercased() ?? ""
                if reason.contains("unauthorized") || reason.contains("token") {
                    // Connect again with a new token. If the refresh fails, the session ends.
                    forceRefresh = true
                    throw Failure.rejected(response)
                }
                // One device that cannot be joined must not stop the others.
                joinRefs[topic] = nil
            }
        }
    }

    private func sendHeartbeats() async throws {
        while true {
            try await Task.sleep(for: Self.heartbeatInterval)
            _ = try await request(PhoenixMessage(joinRef: nil, ref: makeRef(), topic: "phoenix", event: "heartbeat", payload: [:]))
        }
    }

    private func receive(on socket: URLSessionWebSocketTask) async throws {
        while true {
            let text: String
            switch try await socket.receive() {
            case .string(let string): text = string
            case .data(let data): text = String(decoding: data, as: UTF8.self)
            @unknown default: continue
            }
            guard let message = try? PhoenixMessage(text: text) else { continue }
            handle(message)
        }
    }

    private func handle(_ message: PhoenixMessage) {
        switch message.event {
        case "phx_reply":
            guard let ref = message.ref, let continuation = replies.removeValue(forKey: ref) else { return }
            let response = message.payload["response"] ?? .null
            if message.payload["status"]?.stringValue == "ok" {
                continuation.resume(returning: response)
            } else {
                continuation.resume(throwing: Failure.rejected(response))
            }
        case "phx_error", "phx_close":
            // A channel stopped on the server. Connect again and join all topics again.
            socket?.cancel(with: .goingAway, reason: nil)
        default:
            sink.yield(.message(message))
        }
    }

    /// Sends a message and waits for its phx_reply.
    private func request(_ message: PhoenixMessage) async throws -> JSONValue {
        guard let socket, let ref = message.ref else { throw HomeProviderError.offline }
        let text = try message.text()
        return try await withCheckedThrowingContinuation { continuation in
            replies[ref] = continuation
            Task {
                do {
                    try await socket.send(.string(text))
                } catch {
                    self.failReply(ref, with: error)
                    return
                }
                try? await Task.sleep(for: Self.replyTimeout)
                self.failReply(ref, with: Failure.timedOut)
            }
        }
    }

    private func failReply(_ ref: String, with error: Error) {
        replies.removeValue(forKey: ref)?.resume(throwing: error)
    }

    private func failReplies() {
        let waiting = replies
        replies = [:]
        waiting.values.forEach { $0.resume(throwing: HomeProviderError.offline) }
    }

    private func makeRef() -> String {
        nextRef += 1
        return String(nextRef)
    }
}
