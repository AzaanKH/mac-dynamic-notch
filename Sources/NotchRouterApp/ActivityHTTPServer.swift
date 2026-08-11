import Combine
import Foundation
import Network
import NotchRouterCore

@MainActor
final class ActivityHTTPServer: ObservableObject, @unchecked Sendable {
  typealias IngestHandler = @Sendable (ActivityEventRequest) async throws -> AIActivity
  typealias ListHandler = @Sendable () async -> [AIActivity]
  typealias BrowserMediaHandler =
    @Sendable (BrowserMediaEvent) async throws -> BrowserMediaBridgeResponse

  enum State: Equatable, Sendable {
    case stopped
    case starting
    case ready
    case failed(Failure)

    var canRetry: Bool {
      if case .failed = self { return true }
      return false
    }
  }

  struct Failure: Equatable, Sendable {
    let message: String
    let isPortConflict: Bool
  }

  let port: UInt16
  @Published private(set) var state: State = .stopped

  private var token: String
  private let queue = DispatchQueue(label: "com.notchrouter.activity-server")
  private let ingestHandler: IngestHandler
  private let listHandler: ListHandler
  private let browserMediaHandler: BrowserMediaHandler
  private var listener: NWListener?

  init(
    port: UInt16 = 48_271,
    token: String,
    ingestHandler: @escaping IngestHandler,
    listHandler: @escaping ListHandler,
    browserMediaHandler: @escaping BrowserMediaHandler
  ) {
    self.port = port
    self.token = token
    self.ingestHandler = ingestHandler
    self.listHandler = listHandler
    self.browserMediaHandler = browserMediaHandler
  }

  func start() {
    guard state != .starting, state != .ready else { return }

    listener?.cancel()
    listener = nil
    state = .starting

    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(
      host: "127.0.0.1",
      port: NWEndpoint.Port(rawValue: port)!
    )

    let newListener: NWListener
    do {
      newListener = try NWListener(using: parameters)
    } catch {
      state = .failed(Self.failure(for: error, port: port))
      return
    }

    let token = token
    let ingestHandler = ingestHandler
    let listHandler = listHandler
    let browserMediaHandler = browserMediaHandler
    let queue = queue

    newListener.stateUpdateHandler = { [weak self, weak newListener] newState in
      Task { @MainActor in
        guard let self, let newListener, self.listener === newListener else {
          return
        }
        self.handle(newState, from: newListener)
      }
    }
    newListener.newConnectionHandler = { connection in
      HTTPConnection(
        connection: connection,
        token: token,
        ingestHandler: ingestHandler,
        listHandler: listHandler,
        browserMediaHandler: browserMediaHandler
      ).start(on: queue)
    }
    listener = newListener
    newListener.start(queue: queue)
  }

  func stop() {
    listener?.cancel()
    listener = nil
    state = .stopped
  }

  func updateToken(_ token: String) {
    guard token != self.token else { return }
    let shouldRestart = state != .stopped
    stop()
    self.token = token
    if shouldRestart {
      start()
    }
  }

  private func handle(_ newState: NWListener.State, from listener: NWListener) {
    switch newState {
    case .setup:
      state = .starting
    case .waiting(let error):
      let failure = Self.failure(for: error, port: port)
      state = .failed(failure)
      NSLog("NotchRouter activity server is waiting: \(failure.message)")
    case .ready:
      state = .ready
      NSLog("NotchRouter is listening on 127.0.0.1:\(port)")
    case .failed(let error):
      let failure = Self.failure(for: error, port: port)
      state = .failed(failure)
      NSLog("NotchRouter activity server failed: \(failure.message)")
      listener.cancel()
      self.listener = nil
    case .cancelled:
      self.listener = nil
      state = .stopped
    @unknown default:
      break
    }
  }

  private static func failure(for error: Error, port: UInt16) -> Failure {
    let isPortConflict: Bool
    if case NWError.posix(.EADDRINUSE) = error {
      isPortConflict = true
    } else {
      let error = error as NSError
      isPortConflict =
        error.domain == NSPOSIXErrorDomain
        && error.code == Int(POSIXErrorCode.EADDRINUSE.rawValue)
    }

    if isPortConflict {
      return Failure(
        message: "Port \(port) is already in use.",
        isPortConflict: true
      )
    }
    return Failure(
      message: error.localizedDescription,
      isPortConflict: false
    )
  }
}

private final class HTTPConnection: @unchecked Sendable {
  private static let maximumRequestSize = 64 * 1_024

  private let connection: NWConnection
  private let token: String
  private let ingestHandler: ActivityHTTPServer.IngestHandler
  private let listHandler: ActivityHTTPServer.ListHandler
  private let browserMediaHandler: ActivityHTTPServer.BrowserMediaHandler
  private var buffer = Data()
  private var queue: DispatchQueue?

  init(
    connection: NWConnection,
    token: String,
    ingestHandler: @escaping ActivityHTTPServer.IngestHandler,
    listHandler: @escaping ActivityHTTPServer.ListHandler,
    browserMediaHandler: @escaping ActivityHTTPServer.BrowserMediaHandler
  ) {
    self.connection = connection
    self.token = token
    self.ingestHandler = ingestHandler
    self.listHandler = listHandler
    self.browserMediaHandler = browserMediaHandler
  }

  func start(on queue: DispatchQueue) {
    self.queue = queue
    connection.start(queue: queue)
    receive()
  }

  private func receive() {
    connection.receive(
      minimumIncompleteLength: 1,
      maximumLength: 16 * 1_024
    ) { [self] data, _, isComplete, error in
      if let data {
        buffer.append(data)
      }

      if buffer.count > Self.maximumRequestSize {
        send(.text(status: 413, message: "Request is too large"))
        return
      }

      switch HTTPRequest.parse(buffer) {
      case .complete(let request):
        route(request)
      case .malformed:
        send(.text(status: 400, message: "Malformed HTTP request"))
      case .incomplete where isComplete || error != nil:
        send(.text(status: 400, message: "Malformed HTTP request"))
      case .incomplete:
        receive()
      }
    }
  }

  private func route(_ request: HTTPRequest) {
    if request.method == "GET", request.path == "/v1/health" {
      send(.json(status: 200, object: ["status": "ok"]))
      return
    }

    guard request.headers["origin"] == nil else {
      send(.text(status: 403, message: "Browser-origin requests are not accepted"))
      return
    }

    guard request.headers["authorization"] == "Bearer \(token)" else {
      send(.text(status: 401, message: "Missing or invalid bearer token"))
      return
    }

    if request.method == "POST", request.path == "/v1/activities" {
      ingest(request.body)
    } else if request.method == "POST", request.path == "/v1/browser-media" {
      ingestBrowserMedia(request.body)
    } else if request.method == "GET", request.path == "/v1/activities" {
      list()
    } else {
      send(.text(status: 404, message: "Not found"))
    }
  }

  private func ingest(_ body: Data) {
    let event: ActivityEventRequest
    do {
      event = try ActivityCoding.makeDecoder().decode(
        ActivityEventRequest.self,
        from: body
      )
    } catch {
      send(.text(status: 400, message: "Invalid activity JSON: \(error.localizedDescription)"))
      return
    }

    Task {
      do {
        let activity = try await ingestHandler(event)
        let data = try ActivityCoding.makeEncoder().encode(activity)
        send(.data(status: 202, contentType: "application/json", body: data))
      } catch {
        send(.text(status: 422, message: error.localizedDescription))
      }
    }
  }

  private func ingestBrowserMedia(_ body: Data) {
    let event: BrowserMediaEvent
    do {
      event = try ActivityCoding.makeDecoder().decode(
        BrowserMediaEvent.self,
        from: body
      )
    } catch {
      send(.text(status: 400, message: "Invalid browser media JSON"))
      return
    }

    Task {
      do {
        let response = try await browserMediaHandler(event)
        let data = try ActivityCoding.makeEncoder().encode(response)
        send(.data(status: 200, contentType: "application/json", body: data))
      } catch {
        send(.text(status: 422, message: error.localizedDescription))
      }
    }
  }

  private func list() {
    Task {
      let activities = await listHandler()
      do {
        let data = try ActivityCoding.makeEncoder().encode(activities)
        send(.data(status: 200, contentType: "application/json", body: data))
      } catch {
        send(.text(status: 500, message: "Could not encode activity list"))
      }
    }
  }

  private func send(_ response: HTTPResponse) {
    connection.send(
      content: response.encoded,
      completion: .contentProcessed { [connection] _ in
        connection.cancel()
      }
    )
  }
}

struct HTTPRequest {
  let method: String
  let path: String
  let headers: [String: String]
  let body: Data

  enum ParseResult {
    case incomplete
    case malformed
    case complete(HTTPRequest)
  }

  static func parse(_ data: Data) -> ParseResult {
    let separator = Data("\r\n\r\n".utf8)
    guard let headerRange = data.range(of: separator) else {
      return .incomplete
    }
    guard
      let headerText = String(
        data: data[..<headerRange.lowerBound],
        encoding: .utf8
      )
    else { return .malformed }

    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return .malformed }
    let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
    guard
      requestParts.count == 3,
      requestParts[2] == "HTTP/1.1" || requestParts[2] == "HTTP/1.0"
    else { return .malformed }

    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      let parts = line.split(separator: ":", maxSplits: 1)
      guard parts.count == 2 else { return .malformed }
      let name = String(parts[0]).lowercased()
      guard !name.isEmpty, headers[name] == nil else { return .malformed }
      headers[name] = parts[1]
        .trimmingCharacters(in: .whitespaces)
    }

    let contentLength: Int
    if let rawContentLength = headers["content-length"] {
      guard
        !rawContentLength.isEmpty,
        rawContentLength.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
        let parsedContentLength = Int(rawContentLength)
      else {
        return .malformed
      }
      contentLength = parsedContentLength
    } else {
      contentLength = 0
    }

    let bodyStart = headerRange.upperBound
    guard bodyStart <= data.count else { return .malformed }
    guard contentLength <= data.count - bodyStart else { return .incomplete }
    let bodyEnd = bodyStart + contentLength

    return .complete(
      HTTPRequest(
        method: String(requestParts[0]).uppercased(),
        path: String(requestParts[1]).components(separatedBy: "?").first ?? "/",
        headers: headers,
        body: data.subdata(in: bodyStart..<bodyEnd)
      )
    )
  }
}

private struct HTTPResponse {
  let status: Int
  let contentType: String
  let body: Data

  static func text(status: Int, message: String) -> HTTPResponse {
    data(
      status: status,
      contentType: "text/plain; charset=utf-8",
      body: Data(message.utf8)
    )
  }

  static func json(status: Int, object: [String: String]) -> HTTPResponse {
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    return .data(status: status, contentType: "application/json", body: data)
  }

  static func data(
    status: Int,
    contentType: String,
    body: Data
  ) -> HTTPResponse {
    HTTPResponse(status: status, contentType: contentType, body: body)
  }

  var encoded: Data {
    let reason: String
    switch status {
    case 200: reason = "OK"
    case 202: reason = "Accepted"
    case 400: reason = "Bad Request"
    case 401: reason = "Unauthorized"
    case 403: reason = "Forbidden"
    case 404: reason = "Not Found"
    case 413: reason = "Content Too Large"
    case 422: reason = "Unprocessable Content"
    default: reason = "Internal Server Error"
    }
    let headers =
      "HTTP/1.1 \(status) \(reason)\r\n"
      + "Content-Type: \(contentType)\r\n"
      + "Content-Length: \(body.count)\r\n"
      + "Connection: close\r\n"
      + "\r\n"
    var result = Data(headers.utf8)
    result.append(body)
    return result
  }
}
