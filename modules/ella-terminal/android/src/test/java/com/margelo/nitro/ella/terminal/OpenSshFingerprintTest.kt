package com.margelo.nitro.ella.terminal

import java.util.Base64
import org.junit.Assert.assertEquals
import org.junit.Test

class OpenSshFingerprintTest {
  @Test
  fun matchesSshKeygenEd25519Fingerprint() {
    val wireKey = Base64.getDecoder().decode(
      "AAAAC3NzaC1lZDI1NTE5AAAAIGBLpY6iGkp33e9eJ4dHsbGKgOS79ObOGl0BFKmZNcNy",
    )

    assertEquals(
      "SHA256:tAo5AdHa1CXTq79PTL601VaUJpao/L4xAydtYO/uB9s",
      OpenSshFingerprint.sha256(wireKey),
    )
  }
}
