import Darwin
import Foundation
import Network

/// Filesystem ownership is the server identity boundary for bundled clients.
public enum LocalAPISocket {
  public static var url: URL {
    AppPaths.applicationSupportDirectory.appendingPathComponent("api.sock")
  }

  public static func prepareForListening(at url: URL) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
    )
    try checkOwner(directory, kind: S_IFDIR)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    guard url.path.utf8.count < 104 else { throw LocalAPIError.invalidSocket }
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      if errno == ENOENT { return }
      throw LocalAPIError.invalidSocket
    }
    try checkOwner(url, kind: S_IFSOCK)
    // Never unlink an active server. A refused connection identifies a stale socket.
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw LocalAPIError.invalidSocket }
    defer { Darwin.close(fd) }
    _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.copyBytes(from: Array(url.path.utf8) + [0])
    }
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result != 0, errno == ECONNREFUSED else { throw LocalAPIError.socketInUse }
    try FileManager.default.removeItem(at: url)
  }

  public static func secureSocket(at url: URL) throws {
    try checkOwner(url, kind: S_IFSOCK)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  public static func validateServer(at url: URL) throws {
    try checkOwner(url.deletingLastPathComponent(), kind: S_IFDIR, privateMode: true)
    try checkOwner(url, kind: S_IFSOCK, privateMode: true)
  }

  private static func checkOwner(_ url: URL, kind: mode_t, privateMode: Bool = false) throws {
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_uid == geteuid(),
      info.st_mode & S_IFMT == kind,
      !privateMode || info.st_mode & 0o077 == 0
    else { throw LocalAPIError.invalidSocket }
  }
}

public enum LocalAPIError: LocalizedError {
  case invalidSocket, socketInUse, invalidResponse, responseTooLarge, timedOut
  public var errorDescription: String? {
    switch self {
    case .invalidSocket: "NotchRouter's private socket is unavailable or has unsafe ownership or permissions."
    case .socketInUse: "NotchRouter's private socket is already in use."
    case .invalidResponse: "NotchRouter returned an invalid local response."
    case .responseTooLarge: "NotchRouter's response exceeded the size limit."
    case .timedOut: "NotchRouter did not respond in time."
    }
  }
}

public struct LocalAPIResponse: Sendable {
  public let status: Int
  public let body: Data
}

public enum LocalAPIClient {
  public static func request(
    path: String, method: String = "GET", body: Data? = nil, token: String? = nil,
    socketURL: URL = LocalAPISocket.url, timeout: TimeInterval = 4
  ) async throws -> LocalAPIResponse {
    try LocalAPISocket.validateServer(at: socketURL)
    guard path.hasPrefix("/"), !path.contains("\r"), !path.contains("\n"),
      ["GET", "POST"].contains(method),
      token.map({ !$0.contains("\r") && !$0.contains("\n") }) ?? true
    else { throw LocalAPIError.invalidResponse }
    var headers = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
    if let token { headers += "Authorization: Bearer \(token)\r\n" }
    headers += "Content-Type: application/json\r\nContent-Length: \(body?.count ?? 0)\r\n\r\n"
    var data = Data(headers.utf8)
    if let body { data.append(body) }
    let exchange = LocalAPIExchange(socketURL: socketURL, request: data, timeout: timeout)
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await exchange.run()
    } onCancel: { exchange.cancel() }
  }
}

/// All mutable exchange state is confined to queue, including cancellation.
private final class LocalAPIExchange: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.notchrouter.local-api-client")
  private let connection: NWConnection
  private let request: Data
  private let timeout: TimeInterval
  private var continuation: CheckedContinuation<LocalAPIResponse, Error>?
  private var deadline: DispatchWorkItem?
  private var buffer = Data()
  private var finished = false
  private static let maximumResponseBytes = 16 * 1_024 * 1_024

  init(socketURL: URL, request: Data, timeout: TimeInterval) {
    connection = NWConnection(to: .unix(path: socketURL.path), using: .tcp)
    self.request = request
    self.timeout = timeout
  }

  func run() async throws -> LocalAPIResponse {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        guard !finished else { continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let deadline = DispatchWorkItem { [weak self] in self?.finish(.failure(LocalAPIError.timedOut)) }
        self.deadline = deadline
        queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
        connection.stateUpdateHandler = { [weak self] state in
          guard let self else { return }
          if case .failed(let error) = state { self.finish(.failure(error)) }
        }
        connection.start(queue: queue)
        connection.send(content: request, completion: .contentProcessed { [weak self] error in
          guard let self, !self.finished else { return }
          if let error { self.finish(.failure(error)); return }
          self.receive()
        })
      }
    }
  }

  func cancel() { queue.async { self.finish(.failure(CancellationError())) } }

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1_024) { [self] data, _, complete, error in
      guard !finished else { return }
      if let data { buffer.append(data) }
      guard buffer.count <= Self.maximumResponseBytes else {
        finish(.failure(LocalAPIError.responseTooLarge)); return
      }
      if let error { finish(.failure(error)); return }
      do {
        if let response = try Self.parse(buffer) { finish(.success(response)); return }
        if complete { finish(.failure(LocalAPIError.invalidResponse)); return }
        receive()
      } catch { finish(.failure(error)) }
    }
  }

  private static func parse(_ data: Data) throws -> LocalAPIResponse? {
    guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
      guard data.count <= 16 * 1_024 else { throw LocalAPIError.invalidResponse }
      return nil
    }
    guard separator.lowerBound <= 16 * 1_024,
      let header = String(data: data[..<separator.lowerBound], encoding: .utf8)
    else { throw LocalAPIError.invalidResponse }
    let lines = header.components(separatedBy: "\r\n")
    let first = lines[0].split(separator: " ")
    guard first.count >= 2, first[0] == "HTTP/1.1", let status = Int(first[1]) else {
      throw LocalAPIError.invalidResponse
    }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      let parts = line.split(separator: ":", maxSplits: 1)
      guard parts.count == 2 else { throw LocalAPIError.invalidResponse }
      let name = parts[0].lowercased()
      guard headers[name] == nil else { throw LocalAPIError.invalidResponse }
      headers[name] = parts[1].trimmingCharacters(in: .whitespaces)
    }
    guard headers["transfer-encoding"] == nil,
      let value = headers["content-length"], let length = Int(value), length >= 0
    else { throw LocalAPIError.invalidResponse }
    guard length <= maximumResponseBytes - separator.upperBound else { throw LocalAPIError.responseTooLarge }
    guard data.count - separator.upperBound >= length else { return nil }
    // A redirect is returned as a status, never followed to another endpoint.
    return LocalAPIResponse(status: status, body: data.subdata(in: separator.upperBound..<(separator.upperBound + length)))
  }

  private func finish(_ result: Result<LocalAPIResponse, Error>) {
    guard !finished else { return }
    finished = true
    deadline?.cancel()
    deadline = nil
    connection.stateUpdateHandler = nil
    connection.cancel()
    continuation?.resume(with: result)
    continuation = nil
  }
}
