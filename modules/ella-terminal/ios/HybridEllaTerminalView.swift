import NitroModules
import SwiftTerm
import UIKit

final class HybridEllaTerminalView: HybridEllaTerminalViewSpec, TerminalViewDelegate {
  private let terminalView = EllaSwiftTermView(frame: .zero)
  private let containerView = TerminalContainer()
  private var session: EllaSSHSession?
  private var sessionToken: UUID?
  private var pendingConnection: EllaSSHConnectionConfiguration?
  private var controlModifierObserver: NSObjectProtocol?
  private var disposed = false

  var onConnectionStateChange: ((ConnectionStateEvent) -> Void)?
  var onControlModifierChange: ((Bool) -> Void)?
  var onHostKeyRequest: ((HostKeyRequestEvent) -> Void)?
  var headerInset: Double = 0

  var view: UIView { containerView }

  override init() {
    super.init()

    terminalView.terminalDelegate = self
    terminalView.inputAccessoryView = nil
    terminalView.nativeBackgroundColor = .black
    terminalView.nativeForegroundColor = .white
    terminalView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    terminalView.keyboardDismissMode = .interactive
    containerView.install(terminalView)
    controlModifierObserver = NotificationCenter.default.addObserver(
      forName: .terminalViewControlModifierReset,
      object: terminalView,
      queue: .main
    ) { [weak self] _ in
      self?.onControlModifierChange?(false)
    }
    terminalView.onFirstLayout = { [weak terminalView] in
      _ = terminalView?.becomeFirstResponder()
    }
  }

  deinit {
    disposed = true
    pendingConnection = nil
    session?.dispose()
    if let controlModifierObserver {
      NotificationCenter.default.removeObserver(controlModifierObserver)
    }
    terminalView.updateUiClosed()
  }

  func connect(config: ConnectionConfig) throws {
    do {
      let configuration = try EllaSSHConnectionConfiguration(config)
      DispatchQueue.main.async { [weak self] in
        self?.replaceSession(with: configuration)
      }
    } catch {
      DispatchQueue.main.async { [weak self] in
        guard let self, !self.disposed else { return }
        self.onConnectionStateChange?(
          ConnectionStateEvent(
            connectionId: config.connectionId,
            state: .error,
            errorCode: .internalerror,
            message: "Invalid SSH connection configuration."
          )
        )
      }
    }
  }

  func disconnect(connectionId: String) throws {
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.disposed else { return }

      if self.pendingConnection?.connectionId == connectionId {
        self.pendingConnection = nil
      }
      guard self.session?.connectionId == connectionId else { return }
      self.session?.disconnect()
    }
  }

  func respondToHostKey(connectionId: String, requestId: String, accepted: Bool) throws {
    DispatchQueue.main.async { [weak self] in
      guard let session = self?.session, session.connectionId == connectionId else { return }
      session.respondToHostKey(requestId: requestId, accepted: accepted)
    }
  }

  func sendKey(key: TerminalKey) throws {
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.disposed else { return }
      self.terminalView.sendExtraKey(key)
    }
  }

  func setControlModifier(active: Bool) throws {
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.disposed else { return }
      self.terminalView.controlModifier = active
      self.onControlModifierChange?(active)
    }
  }

  func showKeyboard() throws {
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.disposed else { return }
      _ = self.terminalView.becomeFirstResponder()
    }
  }

  func hideKeyboard() throws {
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.disposed else { return }
      _ = self.terminalView.resignFirstResponder()
    }
  }

  func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
    guard newCols > 0, newRows > 0 else { return }
    let cell = terminalView.cellSizeInPixels(source: terminalView.getTerminal())
    session?.resize(
      columns: newCols,
      rows: newRows,
      pixelWidth: (cell?.width ?? 0) * newCols,
      pixelHeight: (cell?.height ?? 0) * newRows
    )
  }

  func setTerminalTitle(source: TerminalView, title: String) {}
  func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

  func send(source: TerminalView, data: ArraySlice<UInt8>) {
    session?.send(data)
  }

  func scrolled(source: TerminalView, position: Double) {}

  func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
    guard
      let url = URL(string: link),
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    else { return }
    UIApplication.shared.open(url)
  }

  func bell(source: TerminalView) {}

  func clipboardCopy(source: TerminalView, content: Data) {
    UIPasteboard.general.string = String(data: content, encoding: .utf8)
  }

  func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
  func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

  private func replaceSession(with configuration: EllaSSHConnectionConfiguration) {
    guard !disposed else { return }
    pendingConnection = configuration

    guard let oldSession = session else {
      startPendingConnection()
      return
    }

    let oldToken = sessionToken
    oldSession.dispose { [weak self] in
      DispatchQueue.main.async {
        guard let self, self.sessionToken == oldToken else { return }
        self.session = nil
        self.sessionToken = nil
        self.startPendingConnection()
      }
    }
  }

  private func startPendingConnection() {
    guard !disposed, session == nil, let configuration = pendingConnection else { return }
    pendingConnection = nil

    let terminal = terminalView.getTerminal()
    let columns = max(terminal.cols, 1)
    let rows = max(terminal.rows, 1)
    let cell = terminalView.cellSizeInPixels(source: terminal)
    let size = EllaTerminalSize(
      columns: columns,
      rows: rows,
      pixelWidth: (cell?.width ?? 0) * columns,
      pixelHeight: (cell?.height ?? 0) * rows
    )

    let token = UUID()
    let connectionId = configuration.connectionId
    let host = configuration.host
    let port = configuration.port
    let newSession = EllaSSHSession(
      configuration: configuration,
      initialSize: size,
      terminalView: terminalView,
      onState: { [weak self] state, code, message in
        DispatchQueue.main.async {
          guard let self, self.sessionToken == token, !self.disposed else { return }
          self.onConnectionStateChange?(
            ConnectionStateEvent(
              connectionId: connectionId,
              state: state,
              errorCode: code,
              message: message
            )
          )
        }
      },
      onHostKey: { [weak self] requestId, algorithm, fingerprint in
        DispatchQueue.main.async {
          guard let self, self.sessionToken == token, !self.disposed else { return }
          self.onHostKeyRequest?(
            HostKeyRequestEvent(
              connectionId: connectionId,
              requestId: requestId,
              host: host,
              port: Double(port),
              algorithm: algorithm,
              fingerprint: fingerprint
            )
          )
        }
      },
      onStopped: { [weak self] in
        DispatchQueue.main.async {
          guard let self, self.sessionToken == token else { return }
          self.session = nil
          self.sessionToken = nil
          self.startPendingConnection()
        }
      }
    )
    session = newSession
    sessionToken = token
    newSession.start()
  }
}

private final class EllaSwiftTermView: TerminalView {
  // Fabric uses this selector to attach a matching React Native InputAccessoryView.
  @objc var inputAccessoryViewID: String? { "ella-terminal-extra-keys" }
  var onFirstLayout: (() -> Void)?

  override func layoutSubviews() {
    super.layoutSubviews()
    guard !bounds.isEmpty, let onFirstLayout else { return }
    self.onFirstLayout = nil
    onFirstLayout()
  }

  func sendExtraKey(_ key: TerminalKey) {
    let terminal = getTerminal()
    let control = controlModifier
    let data: [UInt8]

    switch key {
    case .escape:
      data = EscapeSequences.cmdEsc
    case .tab:
      data = EscapeSequences.cmdTab
    case .left:
      data = control
        ? EscapeSequences.controlLeft
        : (terminal.applicationCursor ? EscapeSequences.moveLeftApp : EscapeSequences.moveLeftNormal)
    case .up:
      data = control
        ? [0x1b, 0x5b, 0x31, 0x3b, 0x35, 0x41]
        : (terminal.applicationCursor ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal)
    case .down:
      data = control
        ? [0x1b, 0x5b, 0x31, 0x3b, 0x35, 0x42]
        : (terminal.applicationCursor ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal)
    case .right:
      data = control
        ? EscapeSequences.controlRight
        : (terminal.applicationCursor ? EscapeSequences.moveRightApp : EscapeSequences.moveRightNormal)
    }

    send(data)
    if control {
      controlModifier = false
    }
  }

}

private final class TerminalContainer: UIView {
  private weak var terminalView: UIView?
  private var terminalBottomConstraint: NSLayoutConstraint?
  private var containerBottomConstraint: NSLayoutConstraint?
  private var keyboardObservers: [NSObjectProtocol] = []

  deinit {
    keyboardObservers.forEach(NotificationCenter.default.removeObserver)
  }

  func install(_ terminalView: UIView) {
    self.terminalView = terminalView
    terminalView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(terminalView)
    keyboardLayoutGuide.usesBottomSafeArea = false
    let terminalBottomConstraint = terminalView.bottomAnchor.constraint(
      equalTo: keyboardLayoutGuide.topAnchor
    )
    let containerBottomConstraint = terminalView.bottomAnchor.constraint(equalTo: bottomAnchor)
    self.terminalBottomConstraint = terminalBottomConstraint
    self.containerBottomConstraint = containerBottomConstraint
    NSLayoutConstraint.activate([
      terminalView.topAnchor.constraint(equalTo: topAnchor),
      terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
      terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
      containerBottomConstraint,
    ])

    let center = NotificationCenter.default
    keyboardObservers = [
      center.addObserver(
        forName: UIResponder.keyboardWillShowNotification,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        self?.animateTerminalToKeyboard(with: notification)
      },
      center.addObserver(
        forName: UIResponder.keyboardWillChangeFrameNotification,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        self?.keyboardWillChangeFrame(notification)
      },
      center.addObserver(
        forName: UIResponder.keyboardWillHideNotification,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        self?.animateTerminalToBottom(with: notification)
      },
    ]
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    updateTerminalBottom()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil {
      updateTerminalBottom()
    }
  }

  private func keyboardWillChangeFrame(_ notification: Notification) {
    guard
      let frameValue = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue
    else { return }
    let keyboardFrame = convert(frameValue.cgRectValue, from: nil)
    if keyboardFrame.minY >= bounds.maxY - 0.5 {
      if containerBottomConstraint?.isActive != true {
        animateTerminalToBottom(with: notification)
      }
      return
    }

    animateTerminalToKeyboard(with: notification)
  }

  private func animateTerminalToKeyboard(with notification: Notification) {
    guard let terminalBottomConstraint, let containerBottomConstraint else { return }
    guard containerBottomConstraint.isActive else { return }
    layoutIfNeeded()
    if let accessoryHeight = terminalView?.inputAccessoryView?.bounds.height,
       accessoryHeight > 0 {
      terminalBottomConstraint.constant = -accessoryHeight
    }
    containerBottomConstraint.isActive = false
    terminalBottomConstraint.isActive = true
    animateLayout(with: notification)
  }

  private func animateTerminalToBottom(with notification: Notification) {
    guard let terminalBottomConstraint, let containerBottomConstraint else { return }
    guard !containerBottomConstraint.isActive else { return }
    layoutIfNeeded()
    terminalBottomConstraint.isActive = false
    containerBottomConstraint.isActive = true
    animateLayout(with: notification)
  }

  private func animateLayout(with notification: Notification) {
    let duration =
      (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?
      .doubleValue ?? 0.25
    let curve =
      (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?
      .uintValue ?? UInt(UIView.AnimationCurve.easeInOut.rawValue)
    let curveOption = UIView.AnimationOptions(rawValue: curve << 16)
    UIView.animate(
      withDuration: duration,
      delay: 0,
      options: [curveOption, .beginFromCurrentState, .allowUserInteraction]
    ) { [weak self] in
      self?.layoutIfNeeded()
    }
  }

  private func updateTerminalBottom() {
    guard
      let accessoryView = terminalView?.inputAccessoryView,
      accessoryView.window != nil
    else { return }

    let guideTop = keyboardLayoutGuide.layoutFrame.minY
    let accessoryTop = accessoryView.convert(accessoryView.bounds, to: self).minY
    let accessoryOffset = min(0, accessoryTop - guideTop)
    if terminalBottomConstraint?.constant != accessoryOffset {
      terminalBottomConstraint?.constant = accessoryOffset
    }
  }
}
