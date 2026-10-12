import Darwin
import Foundation
import Network
import NotchRouterCore
import Testing
@testable import NotchRouterApp

@MainActor
private func securityServer(
  port: UInt16 = 0, socketURL: URL? = nil, timeout: TimeInterval = 2, limit: Int = 64
) -> ActivityHTTPServer {
  ActivityHTTPServer(port: port, token: "old-token", socketURL: socketURL,
    requestTimeout: timeout, connectionLimit: limit,
    ingestHandler: { AIActivity(event: try $0.validated()) }, listHandler: { [] },
    browserMediaHandler: { _ in BrowserMediaBridgeResponse(status: "ok") },
    browserDownloadHandler: { _ in BrowserDownloadBridgeResponse(status: "ok") })
}

@MainActor
private func eventually(_ condition: () -> Bool) async throws {
  for _ in 0..<200 {
    if condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  throw LocalAPIError.timedOut
}

private func send(_ connection: NWConnection, _ text: String) async throws {
  try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
    connection.send(content: Data(text.utf8), completion: .contentProcessed { error in
      if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    })
  }
}

private func response(_ connection: NWConnection) async -> String {
  await withCheckedContinuation { continuation in
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
      continuation.resume(returning: data.map { String(decoding: $0, as: UTF8.self) } ?? "")
    }
  }
}

@MainActor
@Test
func rotationRevokesPartialHeadersAndBodiesWithoutRebinding() async throws {
  let server = securityServer()
  defer { server.stop() }
  server.start()
  try await eventually { server.state == .ready }
  let port = try #require(server.listeningPort)
  for partial in [
    "GET /v1/activities HTTP/1.1\r\nHost: localhost\r\n",
    "POST /v1/activities HTTP/1.1\r\nAuthorization: Bearer old-token\r\nContent-Length: 100\r\n\r\n{",
  ] {
    server.updateToken("old-token")
    let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    defer { connection.cancel() }
    connection.start(queue: .global())
    try await send(connection, partial)
    try await eventually { server.connectionCount == 1 }
    server.updateToken("new-token")
    #expect(server.connectionCount == 0)
    #expect(server.state == .ready)
    #expect(server.listeningPort == port)
    let received = await response(connection)
    #expect(!received.contains("200 OK") && !received.contains("202 Accepted"))
  }
  for (token, status) in [("old-token", 401), ("new-token", 200)] {
    let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    defer { connection.cancel() }
    connection.start(queue: .global())
    try await send(connection, "GET /v1/activities HTTP/1.1\r\nAuthorization: Bearer \(token)\r\n\r\n")
    let received = await response(connection)
    #expect(received.hasPrefix("HTTP/1.1 \(status)"))
  }
}

@MainActor
@Test
func privateSocketAuthenticatesAndWorksWhileLegacyTCPIsDisabled() async throws {
  // Keep below sockaddr_un's path limit even when the OS temporary directory is long.
  let directory = URL(fileURLWithPath: "/tmp/notch-security-\(UUID().uuidString)")
  let socketURL = directory.appendingPathComponent("api.sock")
  let server = securityServer(socketURL: socketURL)
  defer { server.stop(); try? FileManager.default.removeItem(at: directory) }
  server.start()
  try await eventually { server.state == .ready }
  #expect(!server.legacyTCPEnabled)
  #expect(server.legacyTCPState == .stopped)
  try LocalAPISocket.validateServer(at: socketURL)
  let unauthorized = try await LocalAPIClient.request(path: "/v1/activities", token: "incorrect", socketURL: socketURL)
  #expect(unauthorized.status == 401)
  let body = Data(#"{"activity_id":"fixture","source":"test","title":"Work","state":"running"}"#.utf8)
  let accepted = try await LocalAPIClient.request(path: "/v1/activities", method: "POST", body: body, token: "old-token", socketURL: socketURL)
  #expect(accepted.status == 202)
  #expect(String(decoding: accepted.body, as: UTF8.self).contains("fixture"))
  server.updateToken("new-token")
  let old = try await LocalAPIClient.request(path: "/v1/activities", token: "old-token", socketURL: socketURL)
  let current = try await LocalAPIClient.request(path: "/v1/activities", token: "new-token", socketURL: socketURL)
  #expect(old.status == 401 && current.status == 200)
  server.setLegacyTCPEnabled(true)
  try await eventually { server.legacyTCPState == .ready }
  server.setLegacyTCPEnabled(false)
  #expect(server.legacyTCPState == .stopped)
  #expect(server.state == .ready)
  // An active private endpoint must never be unlinked during another startup attempt.
  #expect(throws: LocalAPIError.self) { try LocalAPISocket.prepareForListening(at: socketURL) }
  let health = try await LocalAPIClient.request(path: "/v1/health", socketURL: socketURL)
  #expect(health.status == 200)
}

@MainActor
@Test
func incompleteRequestsExpireAndShutdownClosesAcceptedConnections() async throws {
  let server = securityServer(timeout: 0.15, limit: 1)
  defer { server.stop() }
  server.start()
  try await eventually { server.state == .ready }
  let port = try #require(server.listeningPort)
  let first = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
  defer { first.cancel() }
  first.start(queue: .global())
  try await send(first, "GET /")
  try await eventually { server.connectionCount == 1 }
  let extra = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
  defer { extra.cancel() }
  extra.start(queue: .global())
  try? await send(extra, "GET /")
  #expect(await response(extra) == "")
  try await eventually { server.connectionCount == 0 }
  #expect(await response(first) == "")
  let last = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
  defer { last.cancel() }
  last.start(queue: .global())
  try await send(last, "GET /")
  try await eventually { server.connectionCount == 1 }
  server.stop()
  #expect(server.connectionCount == 0)
  #expect(await response(last) == "")
}

@Test
func privateSocketRejectsUnsafeDirectoriesAndSymlinksBeforeSendingCredentials() async throws {
  let directory = URL(fileURLWithPath: "/tmp/notch-socket-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
  defer { try? FileManager.default.removeItem(at: directory) }
  let fake = directory.appendingPathComponent("api.sock")
  try Data().write(to: fake)
  #expect(throws: LocalAPIError.self) { try LocalAPISocket.validateServer(at: fake) }
  try FileManager.default.removeItem(at: fake)
  let target = directory.appendingPathComponent("private")
  try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  let link = directory.appendingPathComponent("link")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
  #expect(throws: LocalAPIError.self) { try LocalAPISocket.prepareForListening(at: link.appendingPathComponent("api.sock")) }
  do {
    _ = try await LocalAPIClient.request(path: "/v1/activities", token: "must-not-leave", socketURL: fake)
    Issue.record("A missing socket must fail without TCP fallback")
  } catch is LocalAPIError {}
}

/// Blocks the first socket preparation until released, so a test can stop and
/// restart the server while that preparation is still running.
private final class GatedSocketPreparer: @unchecked Sendable {
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var calls = 0

  func waitUntilEntered() -> Bool {
    entered.wait(timeout: .now() + 2) == .success
  }

  func prepare(_ url: URL) throws {
    let isFirst = lock.withLock { calls += 1; return calls == 1 }
    if isFirst {
      entered.signal()
      release.wait()
    }
    try LocalAPISocket.prepareForListening(at: url)
  }
}

@MainActor
@Test
func restartingDuringSocketPreparationLeavesTheNewServerReachable() async throws {
  let directory = URL(fileURLWithPath: "/tmp/notch-prepare-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: directory) }
  let socketURL = directory.appendingPathComponent("api.sock")
  let gate = GatedSocketPreparer()
  let server = ActivityHTTPServer(
    port: 0, token: "old-token", socketURL: socketURL, requestTimeout: 2,
    socketPreparer: { try gate.prepare($0) },
    ingestHandler: { AIActivity(event: try $0.validated()) }, listHandler: { [] },
    browserMediaHandler: { _ in BrowserMediaBridgeResponse(status: "ok") },
    browserDownloadHandler: { _ in BrowserDownloadBridgeResponse(status: "ok") })
  defer { server.stop() }

  server.start()
  let entered = await Task.detached { gate.waitUntilEntered() }.value
  #expect(entered, "The first preparation is running")

  // Stop and restart while the first preparation is blocked mid-flight.
  server.stop()
  server.start()
  try await Task.sleep(for: .milliseconds(50))
  #expect(server.state == .starting, "The restart waits for the earlier preparation")
  gate.release.signal()

  try await eventually { server.state == .ready }
  let health = try await LocalAPIClient.request(path: "/v1/health", socketURL: socketURL)
  #expect(health.status == 200)
}

@MainActor
@Test
func restartingAReadySocketServerRepeatedlyNeverSeesItsOwnSocketAsInUse() async throws {
  let directory = URL(fileURLWithPath: "/tmp/notch-restart-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: directory) }
  let socketURL = directory.appendingPathComponent("api.sock")
  let server = securityServer(socketURL: socketURL)
  defer { server.stop() }

  for attempt in 1...40 {
    server.start()
    try await eventually { server.state == .ready || server.state.canRetry }
    #expect(server.state == .ready, "Restart \(attempt) failed: \(server.state)")
    guard server.state == .ready else { return }
    // Stop and restart immediately, while the old listener is still closing.
    server.stop()
  }
  server.start()
  try await eventually { server.state == .ready }
  let health = try await LocalAPIClient.request(path: "/v1/health", socketURL: socketURL)
  #expect(health.status == 200)
}

/// A loopback port that was free a moment ago, for tests that need to rebind it.
private func unusedLoopbackPort() throws -> UInt16 {
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  guard fd >= 0 else { throw POSIXError(.EBADF) }
  defer { close(fd) }
  var address = sockaddr_in()
  address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  address.sin_family = sa_family_t(AF_INET)
  address.sin_addr.s_addr = inet_addr("127.0.0.1")
  var length = socklen_t(MemoryLayout<sockaddr_in>.size)
  let bound = withUnsafeMutablePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
    }
  }
  guard bound else { throw POSIXError(.EADDRINUSE) }
  return UInt16(bigEndian: address.sin_port)
}

@MainActor
@Test
func togglingLegacyTCPRepeatedlyRebindsTheSamePort() async throws {
  let directory = URL(fileURLWithPath: "/tmp/notch-legacy-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: directory) }
  let port = try unusedLoopbackPort()
  let server = securityServer(port: port, socketURL: directory.appendingPathComponent("api.sock"))
  defer { server.stop() }
  server.start()
  try await eventually { server.state == .ready }
  server.setLegacyTCPEnabled(true)
  try await eventually { server.legacyTCPState == .ready || server.legacyTCPState.canRetry }
  try #require(server.legacyTCPState == .ready, "Initial bind failed: \(server.legacyTCPState)")

  for toggle in 1...20 {
    // Turn it off and straight back on while the old listener still holds the port.
    server.setLegacyTCPEnabled(false)
    server.setLegacyTCPEnabled(true)
    try await eventually { server.legacyTCPState == .ready || server.legacyTCPState.canRetry }
    #expect(server.legacyTCPState == .ready, "Toggle \(toggle) failed: \(server.legacyTCPState)")
    guard server.legacyTCPState == .ready else { return }
  }

  let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
  defer { connection.cancel() }
  connection.start(queue: .global())
  try await send(connection, "GET /v1/health HTTP/1.1\r\n\r\n")
  #expect(await response(connection).hasPrefix("HTTP/1.1 200"))
}
