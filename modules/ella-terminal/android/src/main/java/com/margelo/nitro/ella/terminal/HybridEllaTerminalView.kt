package com.margelo.nitro.ella.terminal

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.platform.ViewCompositionStrategy
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.facebook.react.uimanager.ThemedReactContext
import java.nio.charset.StandardCharsets
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import org.connectbot.terminal.Terminal
import org.connectbot.terminal.TerminalDimensions
import org.connectbot.terminal.TerminalEmulatorFactory

class HybridEllaTerminalView(
  private val reactContext: ThemedReactContext,
) : HybridEllaTerminalViewSpec() {
  override var onConnectionStateChange: ((event: ConnectionStateEvent) -> Unit)? = null
  override var onHostKeyRequest: ((event: HostKeyRequestEvent) -> Unit)? = null
  private val headerInsetState = mutableDoubleStateOf(0.0)
  override var headerInset: Double
    get() = headerInsetState.doubleValue
    set(value) {
      headerInsetState.doubleValue = value.coerceAtLeast(0.0)
    }

  private val viewDropped = AtomicBoolean(false)
  private val hybridDisposed = AtomicBoolean(false)
  private val sessionLock = Any()
  private val mainHandler = Handler(Looper.getMainLooper())
  private val latestDimensions = AtomicReference(TerminalDimensions(rows = 24, columns = 80))
  private var activeConnection: EllaSshConnection? = null
  private var pendingConnection: PendingConnection? = null
  private val clipboard =
    reactContext.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
  private val terminalEmulator = TerminalEmulatorFactory.create(
    defaultForeground = Color(0xFFE8E8E8),
    defaultBackground = Color(0xFF090A0C),
    onKeyboardInput = { bytes ->
      val copy = bytes.copyOf()
      mainHandler.post {
        synchronized(sessionLock) { activeConnection }?.send(copy)
      }
    },
    onResize = { dimensions ->
      mainHandler.post {
        latestDimensions.set(dimensions)
        synchronized(sessionLock) { activeConnection }
          ?.resize(dimensions.columns, dimensions.rows)
      }
    },
    onClipboardCopy = { text ->
      mainHandler.post {
        if (!viewDropped.get()) {
          clipboard.setPrimaryClip(ClipData.newPlainText("terminal", text))
        }
      }
    },
    autoDetectUrls = true,
  )
  private val terminalView = ComposeView(reactContext).apply {
    layoutParams = FrameLayout.LayoutParams(
      ViewGroup.LayoutParams.MATCH_PARENT,
      ViewGroup.LayoutParams.MATCH_PARENT,
    )
    setViewCompositionStrategy(
      ViewCompositionStrategy.DisposeOnDetachedFromWindowOrReleasedFromPool,
    )
    setContent {
      Box(modifier = Modifier.fillMaxSize()) {
        Terminal(
          terminalEmulator = terminalEmulator,
          modifier = Modifier.fillMaxSize(),
          initialFontSize = 13.sp,
          backgroundColor = Color(0xFF090A0C),
          foregroundColor = Color(0xFFE8E8E8),
          selectionBackgroundColor = Color(0xFF315A78),
          selectionForegroundColor = Color.White,
          keyboardEnabled = true,
          showSoftKeyboard = true,
          onHyperlinkClick = { link ->
            mainHandler.post { openLink(link) }
          },
          onPasteRequest = {
            mainHandler.post { pasteClipboard() }
          },
        )
        Box(
          modifier = Modifier
            .fillMaxWidth()
            .height(headerInsetState.doubleValue.toFloat().dp)
            .background(Color(0xFF090A0C)),
        )
      }
    }
  }
  private val outputPump = EllaTerminalOutputPump(
    handler = mainHandler,
    onFeed = { connection, bytes ->
      val current = synchronized(sessionLock) { activeConnection }
      if (!viewDropped.get() && current === connection) {
        terminalEmulator.writeInput(bytes)
      }
    },
    onOverflow = { connection -> connection.failOutputOverflow() },
  )

  override val view = terminalView

  override fun connect(config: ConnectionConfig) {
    val port = config.port.toInt()
    if (
      config.connectionId.isBlank() ||
      config.host.isBlank() ||
      config.username.isBlank() ||
      !config.port.isFinite() ||
      config.port != port.toDouble() ||
      port !in 1..65535
    ) {
      emitInvalidConfiguration(config.connectionId)
      return
    }

    val request = PendingConnection(
      connectionId = config.connectionId,
      host = config.host,
      port = port,
      username = config.username,
      password = config.password.toCharArray(),
      trustedHostKey = config.trustedHostKey,
    )
    synchronized(sessionLock) {
      if (viewDropped.get()) {
        request.clear()
        return
      }
      pendingConnection?.clear()
      pendingConnection = request
      val current = activeConnection
      if (current == null) {
        startPendingConnectionLocked()
      } else {
        current.stop(userInitiated = false)
      }
    }
  }

  override fun disconnect(connectionId: String) {
    synchronized(sessionLock) {
      pendingConnection?.takeIf { it.connectionId == connectionId }?.let {
        pendingConnection = null
        it.clear()
      }
      activeConnection?.takeIf { it.connectionId == connectionId }
        ?.stop(userInitiated = true)
    }
  }

  override fun respondToHostKey(connectionId: String, requestId: String, accepted: Boolean) {
    synchronized(sessionLock) {
      activeConnection?.takeIf { it.connectionId == connectionId }
        ?.respondToHostKey(requestId, accepted)
    }
  }

  override fun onDropView() {
    if (viewDropped.compareAndSet(false, true)) {
      synchronized(sessionLock) {
        pendingConnection?.clear()
        pendingConnection = null
        activeConnection?.stop(userInitiated = false)
      }
      outputPump.invalidate()
      terminalView.disposeComposition()
    }
  }

  override fun dispose() {
    if (hybridDisposed.compareAndSet(false, true)) {
      onDropView()
      super.dispose()
    }
  }

  private fun startPendingConnectionLocked() {
    val request = pendingConnection ?: return
    pendingConnection = null
    outputPump.reset()
    val connection = EllaSshConnection(
      connectionId = request.connectionId,
      host = request.host,
      port = request.port,
      username = request.username,
      password = request.takePassword(),
      trustedHostKey = request.trustedHostKey,
      initialSize = latestDimensions.get(),
      onState = ::handleState,
      onHostKey = ::handleHostKey,
      onOutput = ::handleOutput,
      onStopped = ::handleStopped,
    )
    activeConnection = connection
    connection.start()
  }

  private fun handleState(
    connection: EllaSshConnection,
    state: ConnectionState,
    errorCode: TerminalErrorCode?,
    message: String?,
  ) {
    mainHandler.post {
      val current = synchronized(sessionLock) { activeConnection }
      if (!viewDropped.get() && current === connection) {
        onConnectionStateChange?.invoke(
          ConnectionStateEvent(connection.connectionId, state, errorCode, message),
        )
      }
    }
  }

  private fun handleHostKey(
    connection: EllaSshConnection,
    requestId: String,
    algorithm: String,
    fingerprint: String,
  ) {
    mainHandler.post {
      val current = synchronized(sessionLock) { activeConnection }
      if (!viewDropped.get() && current === connection) {
        onHostKeyRequest?.invoke(
          HostKeyRequestEvent(
            connectionId = connection.connectionId,
            requestId = requestId,
            host = connection.host,
            port = connection.port.toDouble(),
            algorithm = algorithm,
            fingerprint = fingerprint,
          ),
        )
      }
    }
  }

  private fun handleOutput(connection: EllaSshConnection, bytes: ByteArray) {
    outputPump.enqueue(connection, bytes)
  }

  private fun handleStopped(connection: EllaSshConnection) {
    mainHandler.post {
      synchronized(sessionLock) {
        if (activeConnection !== connection) return@post
        activeConnection = null
        if (viewDropped.get()) {
          pendingConnection?.clear()
          pendingConnection = null
        } else {
          startPendingConnectionLocked()
        }
      }
    }
  }

  private fun emitInvalidConfiguration(connectionId: String) {
    mainHandler.post {
      if (!viewDropped.get()) {
        onConnectionStateChange?.invoke(
          ConnectionStateEvent(
            connectionId = connectionId,
            state = ConnectionState.ERROR,
            errorCode = TerminalErrorCode.INTERNALERROR,
            message = "Invalid SSH connection configuration.",
          ),
        )
      }
    }
  }

  private fun pasteClipboard() {
    if (viewDropped.get()) return
    val text = clipboard.primaryClip
      ?.takeIf { it.itemCount > 0 }
      ?.getItemAt(0)
      ?.coerceToText(reactContext)
      ?.toString()
      ?: return
    if (text.isEmpty()) return
    synchronized(sessionLock) { activeConnection }
      ?.send(text.toByteArray(StandardCharsets.UTF_8))
  }

  private fun openLink(link: String) {
    val uri = Uri.parse(link)
    if (uri.scheme?.lowercase() !in setOf("http", "https")) return
    val intent = Intent(Intent.ACTION_VIEW, uri).apply {
      addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    runCatching { reactContext.startActivity(intent) }
  }
}

private class PendingConnection(
  val connectionId: String,
  val host: String,
  val port: Int,
  val username: String,
  private var password: CharArray?,
  val trustedHostKey: TrustedHostKey?,
) {
  fun takePassword(): CharArray = password.also { password = null } ?: CharArray(0)

  fun clear() {
    password?.fill('\u0000')
    password = null
  }
}
