import Darwin
import Foundation

final class SecureSecretBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private let pointer: UnsafeMutableRawPointer
  private let capacity: Int
  private var count: Int

  init(copying data: Data) {
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
}
