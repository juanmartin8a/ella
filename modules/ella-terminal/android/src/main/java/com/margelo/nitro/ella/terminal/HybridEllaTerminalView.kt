package com.margelo.nitro.ella.terminal

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.util.Log
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.inputmethod.InputMethodManager
import com.facebook.react.uimanager.ThemedReactContext
import com.termux.terminal.TerminalSession
import com.termux.terminal.TerminalSessionClient
import com.termux.view.TerminalView
import com.termux.view.TerminalViewClient

class HybridEllaTerminalView(
  private val reactContext: ThemedReactContext,
) : HybridEllaTerminalViewSpec(), TerminalSessionClient, TerminalViewClient {
  private val terminalView = TerminalView(reactContext, null)
  private var session: TerminalSession? = null
  private var textSize = 14

  override val view = terminalView

  init {
    terminalView.setTerminalViewClient(this)
    terminalView.setTextSize(textSize)
    terminalView.isFocusable = true
    terminalView.isFocusableInTouchMode = true
    startLocalSession()
  }

  override fun onDropView() {
    session?.takeIf { it.pid > 0 }?.finishIfRunning()
    session = null
  }

  override fun dispose() {
    onDropView()
    super.dispose()
  }

  private fun startLocalSession() {
    val shell = "/system/bin/sh"
    val home = reactContext.filesDir.absolutePath
    val environment = arrayOf(
      "HOME=$home",
      "TMPDIR=${reactContext.cacheDir.absolutePath}",
      "PATH=/system/bin:/system/xbin:/vendor/bin",
      "TERM=xterm-256color",
    )

    val terminalSession = TerminalSession(
      shell,
      home,
      arrayOf(shell),
      environment,
      2_000,
      this,
    )
    session = terminalSession
    terminalView.attachSession(terminalSession)
  }

  private fun showKeyboard() {
    terminalView.requestFocus()
    val input = reactContext.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
    input.showSoftInput(terminalView, InputMethodManager.SHOW_IMPLICIT)
  }

  override fun onTextChanged(changedSession: TerminalSession) = terminalView.onScreenUpdated()
  override fun onTitleChanged(changedSession: TerminalSession) = Unit
  override fun onSessionFinished(finishedSession: TerminalSession) = Unit

  override fun onCopyTextToClipboard(session: TerminalSession, text: String) {
    val clipboard = reactContext.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    clipboard.setPrimaryClip(ClipData.newPlainText("terminal", text))
  }

  override fun onPasteTextFromClipboard(session: TerminalSession) {
    val clipboard = reactContext.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    val text = clipboard.primaryClip?.getItemAt(0)?.coerceToText(reactContext)?.toString()
    if (!text.isNullOrEmpty()) session.emulator.paste(text)
  }

  override fun onBell(session: TerminalSession) = Unit
  override fun onColorsChanged(session: TerminalSession) = terminalView.invalidate()
  override fun onTerminalCursorStateChange(state: Boolean) = Unit
  override fun getTerminalCursorStyle(): Int? = null

  override fun onScale(scale: Float): Float {
    val newSize = (textSize * scale).toInt().coerceIn(10, 28)
    if (newSize != textSize) {
      textSize = newSize
      terminalView.setTextSize(textSize)
    }
    return 1.0f
  }

  override fun onSingleTapUp(e: MotionEvent) = showKeyboard()
  override fun shouldBackButtonBeMappedToEscape() = false
  override fun shouldEnforceCharBasedInput() = false
  override fun shouldUseCtrlSpaceWorkaround() = false
  override fun isTerminalViewSelected() = terminalView.hasFocus()
  override fun copyModeChanged(copyMode: Boolean) = Unit
  override fun onKeyDown(keyCode: Int, e: KeyEvent, session: TerminalSession) = false
  override fun onKeyUp(keyCode: Int, e: KeyEvent) = false
  override fun onLongPress(event: MotionEvent) = false
  override fun readControlKey() = false
  override fun readAltKey() = false
  override fun readShiftKey() = false
  override fun readFnKey() = false
  override fun onCodePoint(codePoint: Int, ctrlDown: Boolean, session: TerminalSession) = false
  override fun onEmulatorSet() = Unit

  override fun logError(tag: String, message: String) {
    Log.e(tag, message)
  }

  override fun logWarn(tag: String, message: String) {
    Log.w(tag, message)
  }

  override fun logInfo(tag: String, message: String) {
    Log.i(tag, message)
  }

  override fun logDebug(tag: String, message: String) {
    Log.d(tag, message)
  }

  override fun logVerbose(tag: String, message: String) {
    Log.v(tag, message)
  }

  override fun logStackTraceWithMessage(tag: String, message: String, e: Exception) {
    Log.e(tag, message, e)
  }

  override fun logStackTrace(tag: String, e: Exception) {
    Log.e(tag, "Terminal error", e)
  }
}
