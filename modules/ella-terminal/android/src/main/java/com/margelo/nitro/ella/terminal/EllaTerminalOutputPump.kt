package com.margelo.nitro.ella.terminal

import android.os.Handler
import java.util.ArrayDeque

internal class EllaTerminalOutputPump(
  private val handler: Handler,
  private val onFeed: (EllaSshConnection, ByteArray) -> Unit,
  private val onOverflow: (EllaSshConnection) -> Unit,
) {
  private val lock = Any()
  private val chunks = ArrayDeque<OutputChunk>()
  private var queuedBytes = 0
  private var drainScheduled = false
  private var active = true
  private var overflowedConnection: EllaSshConnection? = null

  fun enqueue(connection: EllaSshConnection, bytes: ByteArray) {
    if (bytes.isEmpty()) return
    val shouldSchedule: Boolean
    synchronized(lock) {
      if (!active || overflowedConnection === connection) return
      val last = chunks.peekLast()
      val canCoalesce = last?.connection === connection &&
        last.bytes.size + bytes.size <= MAXIMUM_CHUNK_BYTES
      if (
        queuedBytes + bytes.size > MAXIMUM_QUEUED_BYTES ||
        (!canCoalesce && chunks.size >= MAXIMUM_QUEUED_CHUNKS)
      ) {
        chunks.clear()
        queuedBytes = 0
        overflowedConnection = connection
        handler.post { onOverflow(connection) }
        return
      }
      if (canCoalesce) {
        val combined = ByteArray(last.bytes.size + bytes.size)
        last.bytes.copyInto(combined)
        bytes.copyInto(combined, destinationOffset = last.bytes.size)
        chunks.removeLast()
        chunks.addLast(OutputChunk(connection, combined))
      } else {
        chunks.addLast(OutputChunk(connection, bytes.copyOf()))
      }
      queuedBytes += bytes.size
      shouldSchedule = !drainScheduled
      drainScheduled = true
    }
    if (shouldSchedule) handler.post(::drain)
  }

  fun reset() {
    synchronized(lock) {
      if (!active) return
      chunks.clear()
      queuedBytes = 0
      drainScheduled = false
      overflowedConnection = null
    }
  }

  fun invalidate() {
    synchronized(lock) {
      active = false
      chunks.clear()
      queuedBytes = 0
      drainScheduled = false
      overflowedConnection = null
    }
  }

  private fun drain() {
    val batch = mutableListOf<OutputChunk>()
    synchronized(lock) {
      if (!active) {
        drainScheduled = false
        return
      }
      var batchBytes = 0
      while (chunks.isNotEmpty() && batchBytes < MAXIMUM_DRAIN_BYTES) {
        val chunk = chunks.removeFirst()
        queuedBytes -= chunk.bytes.size
        batchBytes += chunk.bytes.size
        batch.add(chunk)
      }
    }

    batch.forEach { onFeed(it.connection, it.bytes) }
    val shouldReschedule = synchronized(lock) {
      if (active && chunks.isNotEmpty()) {
        true
      } else {
        drainScheduled = false
        false
      }
    }
    if (shouldReschedule) handler.post(::drain)
  }

  private data class OutputChunk(
    val connection: EllaSshConnection,
    val bytes: ByteArray,
  )

  private companion object {
    const val MAXIMUM_QUEUED_BYTES = 2 * 1024 * 1024
    const val MAXIMUM_QUEUED_CHUNKS = 512
    const val MAXIMUM_DRAIN_BYTES = 64 * 1024
    const val MAXIMUM_CHUNK_BYTES = 16 * 1024
  }
}
