import Foundation
import Network
import NotchRouterCore
import Testing

@testable import NotchRouterApp

@Test
func requestParserWaitsForHeadersAndBodyThenReturnsACompleteRequest() throws {
  let headers =
    "post /v1/activities?source=test HTTP/1.1\r\n"
    + "AUTHORIZATION: Bearer token\r\n"
    + "Content-Length: 5\r\n\r\n"

  guard case .incomplete = HTTPRequest.parse(Data(headers.dropLast(1).utf8)) else {
    Issue.record("Expected an unterminated header block to be incomplete")
    return
  }
  guard case .incomplete = HTTPRequest.parse(Data((headers + "1234").utf8)) else {
    Issue.record("Expected a partial body to be incomplete")
    return
  }
  guard case .complete(let request) = HTTPRequest.parse(
    Data((headers + "12345trailing bytes").utf8)
  ) else {
    Issue.record("Expected a complete request")
    return
  }

  #expect(request.method == "POST")
  #expect(request.path == "/v1/activities")
  #expect(request.headers["authorization"] == "Bearer token")
  #expect(request.body == Data("12345".utf8))
}

@Test
func requestParserRejectsInvalidSyntaxAfterHeadersFinish() {
  var invalidUTF8 = Data("GET /v1/health HTTP/1.1\r\nX-Test: ".utf8)
  invalidUTF8.append(0xFF)
  invalidUTF8.append(Data("\r\n\r\n".utf8))

  let malformedRequests = [
    invalidUTF8,
    Data("GET /v1/health\r\n\r\n".utf8),
    Data("GET /v1/health HTTP/2\r\n\r\n".utf8),
    Data("GET /v1/health HTTP/1.1\r\nInvalid header\r\n\r\n".utf8),
    Data(
      ("POST /v1/activities HTTP/1.1\r\n"
        + "Content-Length: 1\r\nContent-Length: 1\r\n\r\na").utf8
    ),
  ]

  for request in malformedRequests {
    guard case .malformed = HTTPRequest.parse(request) else {
      Issue.record("Expected malformed request to be rejected")
      continue
    }
  }
}

@Test
func requestParserRejectsNegativeContentLength() {
  let data = Data(
    "POST /v1/activities HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8
  )

  guard case .malformed = HTTPRequest.parse(data) else {
    Issue.record("Expected a negative Content-Length to be malformed")
    return
  }
}

@Test
func requestParserRejectsOverflowingContentLength() {
  let data = Data(
    ("POST /v1/activities HTTP/1.1\r\n"
      + "Content-Length: 999999999999999999999999999999999999\r\n\r\n").utf8
  )

  guard case .malformed = HTTPRequest.parse(data) else {
    Issue.record("Expected an overflowing Content-Length to be malformed")
    return
  }
}

@Test
func requestParserWaitsForADeclaredBodyWithoutOverflowingRangeMath() {
  let data = Data(
    "POST /v1/activities HTTP/1.1\r\nContent-Length: \(Int.max)\r\n\r\n".utf8
  )

  guard case .incomplete = HTTPRequest.parse(data) else {
    Issue.record("Expected a valid but incomplete body length")
    return
  }
}

@MainActor
@Test
func serverCanStartStopAndRestart() async throws {
  let server = makeServer(port: 0)
  defer { server.stop() }

  server.start()
  #expect(server.state == .starting)
  try await waitForServerState(server) { $0 == .ready }

  server.start()
  #expect(server.state == .ready)

  server.stop()
  #expect(server.state == .stopped)

  server.start()
  try await waitForServerState(server) { $0 == .ready }
}

@MainActor
@Test
func serverReportsBindFailureAndAllowsRetry() async throws {
  let parameters = NWParameters.tcp
  parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
  let occupyingListener = try NWListener(using: parameters)
  defer { occupyingListener.cancel() }
  try await startAndWaitUntilReady(occupyingListener)
  let occupiedPort = try #require(occupyingListener.port?.rawValue)

  let server = makeServer(port: occupiedPort)
  defer { server.stop() }
  server.start()

  try await waitForServerState(server) {
    if case .failed = $0 { return true }
    return false
  }
  guard case .failed(let failure) = server.state else {
    Issue.record("Expected a failed server state")
    return
  }
  #expect(failure.isPortConflict)
  #expect(failure.message == "Port \(occupiedPort) is already in use.")
  #expect(server.state.canRetry)

  occupyingListener.cancel()
  try await Task.sleep(for: .milliseconds(50))
  server.start()
  try await waitForServerState(server) { $0 == .ready }
}

@MainActor
private func makeServer(port: UInt16) -> ActivityHTTPServer {
  ActivityHTTPServer(
    port: port,
    token: "test-token",
    ingestHandler: { event in AIActivity(event: event) },
    listHandler: { [] },
    browserMediaHandler: { _ in BrowserMediaBridgeResponse(status: "ok") }
  )
}

@MainActor
private func waitForServerState(
  _ server: ActivityHTTPServer,
  matching predicate: (ActivityHTTPServer.State) -> Bool
) async throws {
  for _ in 0..<200 {
    if predicate(server.state) { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw HTTPServerTestError.timedOut("server state: \(server.state)")
}

private func startAndWaitUntilReady(_ listener: NWListener) async throws {
  let state = ListenerState()
  listener.stateUpdateHandler = { newState in
    state.set(newState)
  }
  listener.newConnectionHandler = { connection in
    connection.cancel()
  }
  listener.start(queue: DispatchQueue(label: "ActivityHTTPServerTests.listener"))

  for _ in 0..<200 {
    switch state.get() {
    case .ready:
      return
    case .failed(let error):
      throw error
    default:
      try await Task.sleep(for: .milliseconds(10))
    }
  }
  throw HTTPServerTestError.timedOut("occupying listener")
}

private final class ListenerState: @unchecked Sendable {
  private let lock = NSLock()
  private var value: NWListener.State = .setup

  func set(_ newValue: NWListener.State) {
    lock.withLock { value = newValue }
  }

  func get() -> NWListener.State {
    lock.withLock { value }
  }
}

private enum HTTPServerTestError: Error {
  case timedOut(String)
}
