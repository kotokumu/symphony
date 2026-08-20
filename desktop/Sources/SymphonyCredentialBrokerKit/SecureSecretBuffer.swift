import Darwin
import Foundation

public final class SecureSecretBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private let pointer: UnsafeMutableRawPointer
  private let capacity: Int
  private var count: Int

  public init(copying data: Data) {
    capacity = max(data.count, 1)
    count = data.count
    pointer = UnsafeMutableRawPointer.allocate(
      byteCount: capacity,
      alignment: MemoryLayout<UInt8>.alignment
    )
    pointer.initializeMemory(as: UInt8.self, repeating: 0, count: capacity)
    data.withUnsafeBytes { bytes in
      guard let source = bytes.baseAddress, !data.isEmpty else {
        return
      }
      pointer.copyMemory(from: source, byteCount: data.count)
    }
  }

  deinit {
    clear()
    pointer.deallocate()
  }

  func clear() {
    lock.withLock {
      _ = memset_s(pointer, capacity, 0, capacity)
      count = 0
    }
  }

  var retainedByteCount: Int {
    lock.withLock { count }
  }

  func withUnsafeBytes<Result>(
    _ operation: (UnsafeRawBufferPointer) throws -> Result
  ) rethrows -> Result {
    try lock.withLock {
      try operation(UnsafeRawBufferPointer(start: pointer, count: count))
    }
  }

  func withTemporaryData<Result>(
    _ operation: (Data) throws -> Result
  ) rethrows -> Result {
    var data = withUnsafeBytes { Data($0) }
    defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
    return try operation(data)
  }

  var bytesForTesting: [UInt8] {
    lock.withLock {
      Array(UnsafeRawBufferPointer(start: pointer, count: capacity))
    }
  }

  func redacting(_ value: Data) -> Data {
    withTemporaryData { secret in
      guard !secret.isEmpty else { return value }
      let token = String(decoding: secret, as: UTF8.self)
      let patterns = [
        secret,
        Data(secret.base64EncodedString().utf8),
        Data(secret.map { String(format: "%02x", $0) }.joined().utf8),
        Data(Data("x-access-token:\(token)".utf8).base64EncodedString().utf8),
      ]
      var result = value
      let replacement = Data("[REDACTED]".utf8)
      for pattern in patterns where !pattern.isEmpty {
        while let range = result.range(of: pattern) {
          result.replaceSubrange(range, with: replacement)
        }
      }
      return result
    }
  }
}
