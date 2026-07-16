package com.margelo.nitro.ella.terminal

import com.hierynomus.sshj.key.KeyAlgorithm
import com.hierynomus.sshj.key.KeyAlgorithms
import com.hierynomus.sshj.transport.cipher.BlockCiphers
import com.hierynomus.sshj.transport.cipher.ChachaPolyCiphers
import com.hierynomus.sshj.transport.cipher.GcmCiphers
import com.hierynomus.sshj.transport.kex.DHGroups
import com.hierynomus.sshj.transport.kex.ExtInfoClientFactory
import com.hierynomus.sshj.transport.mac.Macs
import java.io.InputStream
import java.io.OutputStream
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.security.MessageDigest
import java.security.PublicKey
import java.util.Collections
import java.util.Base64
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadFactory
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import net.schmizz.sshj.DefaultConfig
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.common.Buffer
import net.schmizz.sshj.common.Factory
import net.schmizz.sshj.common.KeyType
import net.schmizz.sshj.connection.channel.direct.Session
import net.schmizz.sshj.transport.cipher.Cipher
import net.schmizz.sshj.transport.kex.Curve25519SHA256
import net.schmizz.sshj.transport.kex.DHGexSHA256
import net.schmizz.sshj.transport.kex.ECDHNistP
import net.schmizz.sshj.transport.kex.KeyExchange
import net.schmizz.sshj.transport.mac.MAC
import net.schmizz.sshj.transport.verification.HostKeyVerifier
import net.schmizz.sshj.userauth.UserAuthException
import net.schmizz.sshj.userauth.method.AuthPassword
import net.schmizz.sshj.userauth.password.PasswordFinder
import net.schmizz.sshj.userauth.password.Resource
import net.schmizz.keepalive.KeepAliveProvider
import org.connectbot.terminal.TerminalDimensions

internal class EllaSshConnection(
  val connectionId: String,
  val host: String,
  val port: Int,
  username: String,
  password: CharArray,
  private val trustedHostKey: TrustedHostKey?,
  initialSize: TerminalDimensions,
  private val onState: (EllaSshConnection, ConnectionState, TerminalErrorCode?, String?) -> Unit,
  private val onHostKey: (EllaSshConnection, String, String, String) -> Unit,
  private val onOutput: (EllaSshConnection, ByteArray) -> Unit,
  private val onStopped: (EllaSshConnection) -> Unit,
) {
  private val stopped = AtomicBoolean(false)
  private val cancelled = AtomicBoolean(false)
  private val userCancelled = AtomicBoolean(false)
  private val connected = AtomicBoolean(false)
  private val watchdogExpired = AtomicBoolean(false)
  private val explicitFailure = AtomicReference<SshFailure?>(null)
  private val pendingHostKey = AtomicReference<PendingHostKey?>(null)
  private val acceptedHostKey = AtomicReference<HostKeyIdentity?>(null)
  private val size = AtomicReference(initialSize.sanitized())
  private val ioExecutor = Executors.newFixedThreadPool(4, namedThreadFactory("ella-ssh-io"))
  private val writerExecutor = Executors.newSingleThreadExecutor(namedThreadFactory("ella-ssh-writer"))
  private val scheduler = Executors.newSingleThreadScheduledExecutor(namedThreadFactory("ella-ssh-timer"))
  private val resizeLock = Any()

  @Volatile private var username: String? = username
  @Volatile private var credential: CharArray? = password
  @Volatile private var client: SSHClient? = null
  @Volatile private var session: Session? = null
  @Volatile private var shell: Session.Shell? = null
  @Volatile private var standardOutput: InputStream? = null
  @Volatile private var errorOutput: InputStream? = null
  @Volatile private var writer: OutputStream? = null
  @Volatile private var watchdog: Future<*>? = null
  @Volatile private var resizeTask: Future<*>? = null
  @Volatile private var phase = Phase.CONNECTING

  fun start() {
    emit(ConnectionState.CONNECTING)
    ioExecutor.execute(::connect)
  }

  fun stop(userInitiated: Boolean) {
    if (stopped.get()) return
    if (userInitiated && userCancelled.compareAndSet(false, true)) {
      emit(ConnectionState.DISCONNECTING)
    }
    cancelled.set(true)
    pendingHostKey.getAndSet(null)?.cancel()
    try {
      ioExecutor.execute {
        finish(SshFailure.CANCELLED, emitFailure = userInitiated)
      }
    } catch (_: RejectedExecutionException) {
      finish(SshFailure.CANCELLED, emitFailure = userInitiated)
    }
  }

  fun respondToHostKey(requestId: String, accepted: Boolean) {
    val pending = pendingHostKey.get() ?: return
    pending.respond(requestId, accepted)
  }

  fun failOutputOverflow() {
    if (stopped.get()) return
    try {
      ioExecutor.execute { finish(SshFailure.INTERNAL_ERROR) }
    } catch (_: RejectedExecutionException) {
      finish(SshFailure.INTERNAL_ERROR)
    }
  }

  fun send(bytes: ByteArray) {
    if (bytes.isEmpty() || !connected.get() || stopped.get()) return
    val copy = bytes.copyOf()
    try {
      writerExecutor.execute {
        if (!connected.get() || stopped.get()) return@execute
        try {
          writer?.write(copy)
          writer?.flush()
        } catch (_: Exception) {
          finish(SshFailure.REMOTE_CLOSED)
        }
      }
    } catch (_: RejectedExecutionException) {
      // The connection is already stopping.
    }
  }

  fun resize(columns: Int, rows: Int) {
    if (columns <= 0 || rows <= 0 || stopped.get()) return
    size.set(TerminalDimensions(rows = rows, columns = columns))
    if (!connected.get()) return
    synchronized(resizeLock) {
      resizeTask?.cancel(false)
      resizeTask = try {
        scheduler.schedule({ flushResize() }, RESIZE_DELAY_MS, TimeUnit.MILLISECONDS)
      } catch (_: RejectedExecutionException) {
        null
      }
    }
  }

  private fun connect() {
    try {
      val ssh = SSHClient(createSecureConfig())
      client = ssh
      ssh.connectTimeout = NETWORK_TIMEOUT_MS
      ssh.transport.timeoutMs = HOST_KEY_TIMEOUT_MS + NETWORK_TIMEOUT_MS
      ssh.connection.keepAlive.keepAliveInterval = KEEPALIVE_SECONDS
      ssh.addHostKeyVerifier(createHostKeyVerifier())

      armWatchdog(SshFailure.CONNECTION_TIMEOUT)
      ssh.connect(host, port)
      ensureActive()

      phase = Phase.AUTHENTICATING
      emit(ConnectionState.AUTHENTICATING)
      armWatchdog(SshFailure.CONNECTION_TIMEOUT)
      authenticatePasswordOnly(ssh)
      ensureActive()

      phase = Phase.SETTING_UP_TERMINAL
      armWatchdog(SshFailure.PTY_FAILED)
      val sshSession = ssh.startSession()
      session = sshSession
      val dimensions = size.get().sanitized()
      sshSession.allocatePTY(
        TERMINAL_TYPE,
        dimensions.columns,
        dimensions.rows,
        0,
        0,
        emptyMap(),
      )
      val sshShell = sshSession.startShell()
      shell = sshShell
      writer = sshShell.outputStream
      standardOutput = sshShell.inputStream
      errorOutput = sshShell.errorStream
      ensureActive()

      phase = Phase.CONNECTED
      connected.set(true)
      cancelWatchdog()
      emit(ConnectionState.CONNECTED)
      startReader(standardOutput)
      startReader(errorOutput)
      flushResize()
      sshShell.join()
      if (!cancelled.get()) finish(SshFailure.REMOTE_CLOSED)
    } catch (error: Throwable) {
      if (!stopped.get()) {
        val failure = explicitFailure.getAndSet(null) ?: classify(error)
        finish(failure, emitFailure = !cancelled.get())
      }
    } finally {
      clearCredential()
    }
  }

  private fun authenticatePasswordOnly(ssh: SSHClient) {
    val username = username.also { username = null }
      ?: throw IllegalStateException("Missing username")
    val password = credential.also { credential = null }
      ?: throw IllegalStateException("Missing credential")
    val finder = object : PasswordFinder {
      override fun reqPassword(resource: Resource<*>?): CharArray = password.clone()
      override fun shouldRetry(resource: Resource<*>?): Boolean = false
    }
    try {
      ssh.auth(username, AuthPassword(finder))
    } finally {
      password.fill('\u0000')
    }
  }

  private fun createHostKeyVerifier(): HostKeyVerifier = object : HostKeyVerifier {
    override fun findExistingAlgorithms(hostname: String?, port: Int): List<String> {
      val algorithm = trustedHostKey?.algorithm ?: acceptedHostKey.get()?.algorithm
      return when (algorithm) {
        "ssh-rsa" -> listOf("rsa-sha2-512", "rsa-sha2-256")
        null -> Collections.emptyList()
        else -> listOf(algorithm)
      }
    }

    override fun verify(hostname: String?, port: Int, key: PublicKey): Boolean {
      val identity = try {
        hostKeyIdentity(key)
      } catch (_: Exception) {
        explicitFailure.set(SshFailure.INTERNAL_ERROR)
        return false
      }

      trustedHostKey?.let { trusted ->
        if (trusted.algorithm == identity.algorithm && trusted.fingerprint == identity.fingerprint) {
          return true
        }
        explicitFailure.set(SshFailure.HOST_KEY_MISMATCH)
        return false
      }

      acceptedHostKey.get()?.let { accepted ->
        if (accepted == identity) return true
        explicitFailure.set(SshFailure.HOST_KEY_MISMATCH)
        return false
      }

      val request = PendingHostKey(UUID.randomUUID().toString(), identity)
      if (!pendingHostKey.compareAndSet(null, request)) {
        explicitFailure.set(SshFailure.INTERNAL_ERROR)
        return false
      }
      cancelWatchdog()
      emit(ConnectionState.AWAITINGHOSTKEY)
      onHostKey(this@EllaSshConnection, request.requestId, identity.algorithm, identity.fingerprint)

      val signalled = try {
        request.latch.await(HOST_KEY_TIMEOUT_MS.toLong(), TimeUnit.MILLISECONDS)
      } catch (_: InterruptedException) {
        Thread.currentThread().interrupt()
        false
      }
      pendingHostKey.compareAndSet(request, null)
      if (cancelled.get()) return false

      return when (request.decision.get()) {
        HostKeyDecision.ACCEPTED -> {
          acceptedHostKey.compareAndSet(null, request.identity)
          armWatchdog(SshFailure.CONNECTION_TIMEOUT)
          true
        }
        HostKeyDecision.REJECTED -> {
          explicitFailure.set(SshFailure.HOST_KEY_REJECTED)
          false
        }
        null -> {
          explicitFailure.set(
            if (signalled) SshFailure.HOST_KEY_REJECTED else SshFailure.HOST_KEY_TIMEOUT,
          )
          false
        }
      }
    }
  }

  private fun startReader(stream: InputStream?) {
    if (stream == null) return
    ioExecutor.execute {
      val buffer = ByteArray(READ_BUFFER_SIZE)
      try {
        while (!cancelled.get()) {
          val count = stream.read(buffer)
          if (count < 0) break
          if (count > 0) onOutput(this, buffer.copyOf(count))
        }
      } catch (_: Exception) {
        if (!cancelled.get()) finish(SshFailure.REMOTE_CLOSED)
      }
    }
  }

  private fun flushResize() {
    synchronized(resizeLock) { resizeTask = null }
    if (!connected.get() || stopped.get()) return
    val dimensions = size.get().sanitized()
    try {
      shell?.changeWindowDimensions(dimensions.columns, dimensions.rows, 0, 0)
    } catch (_: Exception) {
      finish(SshFailure.REMOTE_CLOSED)
    }
  }

  private fun armWatchdog(failure: SshFailure) {
    cancelWatchdog()
    watchdogExpired.set(false)
    watchdog = try {
      scheduler.schedule({
        if (stopped.get() || pendingHostKey.get() != null) return@schedule
        watchdogExpired.set(true)
        explicitFailure.compareAndSet(null, failure)
        runCatching { client?.close() }
      }, NETWORK_TIMEOUT_MS.toLong(), TimeUnit.MILLISECONDS)
    } catch (_: RejectedExecutionException) {
      null
    }
  }

  private fun cancelWatchdog() {
    watchdog?.cancel(false)
    watchdog = null
  }

  private fun ensureActive() {
    if (cancelled.get() || stopped.get()) throw InterruptedException("Connection cancelled")
  }

  private fun classify(error: Throwable): SshFailure {
    if (cancelled.get()) return SshFailure.CANCELLED
    if (watchdogExpired.get() || error is SocketTimeoutException) {
      return if (phase == Phase.SETTING_UP_TERMINAL) {
        SshFailure.PTY_FAILED
      } else {
        SshFailure.CONNECTION_TIMEOUT
      }
    }
    if (error is ConnectException) return SshFailure.CONNECTION_REFUSED
    if (error is UserAuthException) {
      return if (client?.userAuth?.allowedMethods?.contains("password") == false) {
        SshFailure.AUTH_UNSUPPORTED
      } else {
        SshFailure.AUTHENTICATION_FAILED
      }
    }
    return when (phase) {
      Phase.SETTING_UP_TERMINAL -> SshFailure.PTY_FAILED
      Phase.CONNECTED -> SshFailure.REMOTE_CLOSED
      else -> SshFailure.INTERNAL_ERROR
    }
  }

  private fun finish(failure: SshFailure, emitFailure: Boolean = true) {
    if (!stopped.compareAndSet(false, true)) return
    cancelled.set(true)
    connected.set(false)
    pendingHostKey.getAndSet(null)?.cancel()
    cancelWatchdog()
    synchronized(resizeLock) {
      resizeTask?.cancel(false)
      resizeTask = null
    }
    clearCredential()

    val output = writer.also { writer = null }
    val stdout = standardOutput.also { standardOutput = null }
    val stderr = errorOutput.also { errorOutput = null }
    val currentShell = shell.also { shell = null }
    val currentSession = session.also { session = null }
    val currentClient = client.also { client = null }
    runCatching { output?.close() }
    runCatching { stdout?.close() }
    runCatching { stderr?.close() }
    runCatching { currentShell?.close() }
    runCatching { currentSession?.close() }
    runCatching { currentClient?.close() }

    writerExecutor.shutdownNow()
    scheduler.shutdownNow()
    ioExecutor.shutdownNow()

    if (emitFailure) {
      if (userCancelled.get()) {
        emit(
          ConnectionState.DISCONNECTED,
          TerminalErrorCode.CANCELLED,
          SshFailure.CANCELLED.message,
        )
      } else {
        emit(ConnectionState.ERROR, failure.code, failure.message)
      }
    }
    onStopped(this)
  }

  private fun clearCredential() {
    username = null
    credential?.fill('\u0000')
    credential = null
  }

  private fun emit(
    state: ConnectionState,
    errorCode: TerminalErrorCode? = null,
    message: String? = null,
  ) {
    onState(this, state, errorCode, message)
  }

  private enum class Phase {
    CONNECTING,
    AUTHENTICATING,
    SETTING_UP_TERMINAL,
    CONNECTED,
  }

  private enum class SshFailure(val code: TerminalErrorCode, val message: String) {
    CONNECTION_TIMEOUT(TerminalErrorCode.CONNECTIONTIMEOUT, "Connection timed out."),
    CONNECTION_REFUSED(TerminalErrorCode.CONNECTIONREFUSED, "Connection was refused."),
    HOST_KEY_REJECTED(TerminalErrorCode.HOSTKEYREJECTED, "Host key was rejected."),
    HOST_KEY_TIMEOUT(TerminalErrorCode.HOSTKEYTIMEOUT, "Host key confirmation timed out."),
    HOST_KEY_MISMATCH(TerminalErrorCode.HOSTKEYMISMATCH, "Host key does not match the trusted key."),
    AUTH_UNSUPPORTED(TerminalErrorCode.AUTHUNSUPPORTED, "The server does not support password authentication."),
    AUTHENTICATION_FAILED(TerminalErrorCode.AUTHENTICATIONFAILED, "Authentication failed."),
    PTY_FAILED(TerminalErrorCode.PTYFAILED, "Remote terminal setup failed."),
    REMOTE_CLOSED(TerminalErrorCode.REMOTECLOSED, "Remote session closed."),
    CANCELLED(TerminalErrorCode.CANCELLED, "Connection cancelled."),
    INTERNAL_ERROR(TerminalErrorCode.INTERNALERROR, "SSH session failed."),
  }

  companion object {
    private const val NETWORK_TIMEOUT_MS = 15_000
    private const val HOST_KEY_TIMEOUT_MS = 60_000
    private const val KEEPALIVE_SECONDS = 30
    private const val RESIZE_DELAY_MS = 50L
    private const val READ_BUFFER_SIZE = 16 * 1024
    private const val TERMINAL_TYPE = "xterm-256color"

    private val threadNumber = AtomicInteger(0)

    private fun namedThreadFactory(prefix: String) = ThreadFactory { runnable ->
      Thread(runnable, "$prefix-${threadNumber.incrementAndGet()}").apply { isDaemon = true }
    }

    private fun TerminalDimensions.sanitized() = TerminalDimensions(
      rows = rows.coerceAtLeast(1),
      columns = columns.coerceAtLeast(1),
    )

    private fun hostKeyIdentity(key: PublicKey): HostKeyIdentity {
      val keyType = KeyType.fromKey(key)
      require(keyType != KeyType.UNKNOWN && keyType != KeyType.DSA && keyType != KeyType.DSA_CERT)
      val wireKey = Buffer.PlainBuffer().also { keyType.putPubKeyIntoBuffer(key, it) }.compactData
      return HostKeyIdentity(keyType.toString(), OpenSshFingerprint.sha256(wireKey))
    }

    private fun createSecureConfig(): DefaultConfig = DefaultConfig().apply {
      keepAliveProvider = KeepAliveProvider.KEEP_ALIVE
      keyExchangeFactories = listOf<Factory.Named<KeyExchange>>(
        Curve25519SHA256.Factory(),
        Curve25519SHA256.FactoryLibSsh(),
        DHGexSHA256.Factory(),
        ECDHNistP.Factory521(),
        ECDHNistP.Factory384(),
        ECDHNistP.Factory256(),
        DHGroups.Group14SHA256(),
        DHGroups.Group15SHA512(),
        DHGroups.Group16SHA512(),
        DHGroups.Group17SHA512(),
        DHGroups.Group18SHA512(),
        ExtInfoClientFactory(),
      )
      cipherFactories = listOf<Factory.Named<Cipher>>(
        ChachaPolyCiphers.CHACHA_POLY_OPENSSH(),
        GcmCiphers.AES256GCM(),
        GcmCiphers.AES128GCM(),
        BlockCiphers.AES256CTR(),
        BlockCiphers.AES192CTR(),
        BlockCiphers.AES128CTR(),
      )
      macFactories = listOf<Factory.Named<MAC>>(
        Macs.HMACSHA2512Etm(),
        Macs.HMACSHA2256Etm(),
        Macs.HMACSHA2512(),
        Macs.HMACSHA2256(),
      )
      keyAlgorithms = listOf<Factory.Named<KeyAlgorithm>>(
        KeyAlgorithms.EdDSA25519CertV01(),
        KeyAlgorithms.EdDSA25519(),
        KeyAlgorithms.ECDSASHANistp521CertV01(),
        KeyAlgorithms.ECDSASHANistp521(),
        KeyAlgorithms.ECDSASHANistp384CertV01(),
        KeyAlgorithms.ECDSASHANistp384(),
        KeyAlgorithms.ECDSASHANistp256CertV01(),
        KeyAlgorithms.ECDSASHANistp256(),
        KeyAlgorithms.RSASHA512(),
        KeyAlgorithms.RSASHA256(),
      )
    }
  }
}

internal object OpenSshFingerprint {
  fun sha256(wireKey: ByteArray): String {
    val digest = MessageDigest.getInstance("SHA-256").digest(wireKey)
    return "SHA256:${Base64.getEncoder().withoutPadding().encodeToString(digest)}"
  }
}

internal data class HostKeyIdentity(val algorithm: String, val fingerprint: String)

internal class PendingHostKey(
  val requestId: String,
  val identity: HostKeyIdentity,
) {
  val latch = CountDownLatch(1)
  val decision = AtomicReference<HostKeyDecision?>(null)

  fun respond(responseRequestId: String, accepted: Boolean): Boolean {
    if (responseRequestId != requestId) return false
    val requestedDecision =
      if (accepted) HostKeyDecision.ACCEPTED else HostKeyDecision.REJECTED
    if (!decision.compareAndSet(null, requestedDecision)) return false
    latch.countDown()
    return true
  }

  fun cancel() {
    latch.countDown()
  }
}

internal enum class HostKeyDecision {
  ACCEPTED,
  REJECTED,
}
