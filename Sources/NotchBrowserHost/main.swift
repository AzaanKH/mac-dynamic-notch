import Foundation
import NotchRouterCore

@main
enum NotchBrowserHost {
  private static let maximumMessageSize = 64 * 1_024

  static func main() async {
    while true {
      do {
        guard let message = try readMessage() else { return }
        let response: Data
        do {
          response = try await forward(message)
        } catch {
          response = try ActivityCoding.makeEncoder().encode(
            BrowserMediaBridgeResponse(status: "offline")
          )
        }
        try writeMessage(response)
      } catch {
        return
      }
    }
  }

  private static func readMessage() throws -> Data? {
    guard let header = try readExactly(4) else { return nil }
    let length = header.withUnsafeBytes {
      $0.loadUnaligned(as: UInt32.self).littleEndian
    }
    guard length > 0, length <= maximumMessageSize else {
      throw BrowserHostError.invalidMessageSize
    }
    return try readExactly(Int(length))
  }

  private static func readExactly(_ count: Int) throws -> Data? {
    var result = Data()
    while result.count < count {
      guard
        let chunk = try FileHandle.standardInput.read(
          upToCount: count - result.count
        ),
        !chunk.isEmpty
      else {
        if result.isEmpty { return nil }
        throw BrowserHostError.truncatedMessage
      }
      result.append(chunk)
    }
    return result
  }

  private static func writeMessage(_ data: Data) throws {
    guard data.count <= maximumMessageSize else {
      throw BrowserHostError.invalidMessageSize
    }
    var length = UInt32(data.count).littleEndian
    let header = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
    try FileHandle.standardOutput.write(contentsOf: header)
    try FileHandle.standardOutput.write(contentsOf: data)
  }

  private static func forward(_ body: Data) async throws -> Data {
    var request = URLRequest(
      url: URL(string: "http://127.0.0.1:48271/v1/browser-media")!
    )
    request.httpMethod = "POST"
    request.httpBody = body
    request.timeoutInterval = 2
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(
      "Bearer \(try IntegrationToken.loadOrCreate())",
      forHTTPHeaderField: "Authorization"
    )

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let response = response as? HTTPURLResponse,
      (200..<300).contains(response.statusCode)
    else {
      throw BrowserHostError.invalidResponse
    }
    return data
  }
}

private enum BrowserHostError: Error {
  case invalidMessageSize
  case truncatedMessage
  case invalidResponse
}
