import Foundation
import SwiftTerm

final class EllaTerminalOutputPump {
  private let lock = NSLock()
  private weak var terminalView: TerminalView?
  private var chunks: [[UInt8]] = []
  private var readIndex = 0
  private var queuedBytes = 0
  private var drainScheduled = false
  private var active = true
  private let onOverflow: () -> Void

  private static let maximumQueuedBytes = 2 * 1024 * 1024
  private static let maximumQueuedChunks = 512
  private static let maximumDrainBytes = 64 * 1024
  private static let maximumFeedBytes = 16 * 1024

  init(terminalView: TerminalView, onOverflow: @escaping () -> Void) {
    self.terminalView = terminalView
    self.onOverflow = onOverflow
  }

  func enqueue(_ bytes: [UInt8]) {
    guard !bytes.isEmpty else { return }

    lock.lock()
    guard active else {
      lock.unlock()
      return
    }
    let canCoalesce = readIndex < chunks.count &&
      chunks[chunks.count - 1].count + bytes.count <= Self.maximumFeedBytes
    guard
      queuedBytes + bytes.count <= Self.maximumQueuedBytes,
      canCoalesce || chunks.count - readIndex < Self.maximumQueuedChunks
    else {
      active = false
      chunks.removeAll(keepingCapacity: false)
      readIndex = 0
      queuedBytes = 0
      lock.unlock()
      onOverflow()
      return
    }

    if canCoalesce {
      chunks[chunks.count - 1].append(contentsOf: bytes)
    } else {
      chunks.append(bytes)
    }
    queuedBytes += bytes.count
    let shouldSchedule = !drainScheduled
    drainScheduled = true
    lock.unlock()

    if shouldSchedule {
      DispatchQueue.main.async { [weak self] in
        self?.drain()
      }
    }
  }

  func invalidate() {
    lock.lock()
    active = false
    chunks.removeAll(keepingCapacity: false)
    readIndex = 0
    queuedBytes = 0
    lock.unlock()
  }

  private func drain() {
    var batch: [[UInt8]] = []
    var batchBytes = 0

    lock.lock()
    guard active else {
      drainScheduled = false
      lock.unlock()
      return
    }
    while readIndex < chunks.count, batchBytes < Self.maximumDrainBytes {
      let chunk = chunks[readIndex]
      readIndex += 1
      queuedBytes -= chunk.count
      batch.append(chunk)
      batchBytes += chunk.count
    }
    let hasMore = readIndex < chunks.count
    if !hasMore {
      chunks.removeAll(keepingCapacity: true)
      readIndex = 0
    } else if readIndex >= 256 {
      chunks.removeFirst(readIndex)
      readIndex = 0
    }
    drainScheduled = hasMore
    lock.unlock()

    for bytes in batch {
      var offset = 0
      while offset < bytes.count {
        let end = min(offset + Self.maximumFeedBytes, bytes.count)
        terminalView?.feed(byteArray: bytes[offset..<end])
        offset = end
      }
    }

    if hasMore {
      DispatchQueue.main.async { [weak self] in
        self?.drain()
      }
    }
  }
}
