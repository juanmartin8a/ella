package com.margelo.nitro.ella.terminal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PendingHostKeyTest {
  @Test
  fun ignoresStaleAndDuplicateResponses() {
    val pending = PendingHostKey(
      requestId = "current-request",
      identity = HostKeyIdentity("ssh-ed25519", "SHA256:test"),
    )

    assertFalse(pending.respond("stale-request", true))
    assertEquals(1, pending.latch.count)
    assertTrue(pending.respond("current-request", true))
    assertEquals(HostKeyDecision.ACCEPTED, pending.decision.get())
    assertFalse(pending.respond("current-request", false))
  }
}
