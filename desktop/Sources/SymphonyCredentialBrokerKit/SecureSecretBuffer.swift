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
}
