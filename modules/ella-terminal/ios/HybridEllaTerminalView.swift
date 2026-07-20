import NitroModules
import SwiftTerm
import UIKit

final class HybridEllaTerminalView: HybridEllaTerminalViewSpec, TerminalViewDelegate {
  private let terminalView = EllaSwiftTermView(frame: .zero)
  private let containerView = KeyboardAvoidingTerminalContainer()
  private var session: EllaSSHSession?
  private var sessionToken: UUID?
  private var pendingConnection: EllaSSHConnectionConfiguration?
  private var disposed = false

  var onConnectionStateChange: ((ConnectionStateEvent) -> Void)?
  var onHostKeyRequest: ((HostKeyRequestEvent) -> Void)?
  var headerInset: Double = 0 {
    didSet {
      containerView.headerInset = CGFloat(max(0, headerInset))
    }
  }

  var view: UIView { containerView }

  override init() {
    super.init()

    terminalView.terminalDelegate = self
    terminalView.nativeBackgroundColor = .black
    terminalView.nativeForegroundColor = .white
    terminalView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    terminalView.keyboardDismissMode = .interactive
    containerView.install(terminalView)
    terminalView.onFirstLayout = { [weak terminalView] in
      _ = terminalView?.becomeFirstResponder()
    }
  }

  deinit {
    disposed = true
    pendingConnection = nil
    session?.dispose()
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
  var onFirstLayout: (() -> Void)?

  override func layoutSubviews() {
    super.layoutSubviews()
    guard !bounds.isEmpty, let onFirstLayout else { return }
    self.onFirstLayout = nil
    onFirstLayout()
  }
}

private final class KeyboardAvoidingTerminalContainer: UIView {
  private let headerCoverView = UIView()
  private var terminalBottomConstraint: NSLayoutConstraint?
  private var headerCoverHeightConstraint: NSLayoutConstraint?
  private var keyboardFrame: CGRect?
  private var keyboardObserver: NSObjectProtocol?

  deinit {
    if let keyboardObserver {
      NotificationCenter.default.removeObserver(keyboardObserver)
    }
  }

  func install(_ terminalView: UIView) {
    terminalView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(terminalView)
    let terminalBottomConstraint = terminalView.bottomAnchor.constraint(equalTo: bottomAnchor)
    self.terminalBottomConstraint = terminalBottomConstraint
    NSLayoutConstraint.activate([
      terminalView.topAnchor.constraint(equalTo: topAnchor),
      terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
      terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
      terminalBottomConstraint,
    ])

    headerCoverView.backgroundColor = .black
    headerCoverView.isUserInteractionEnabled = false
    headerCoverView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(headerCoverView)
    let headerCoverHeightConstraint = headerCoverView.heightAnchor.constraint(equalToConstant: 0)
    self.headerCoverHeightConstraint = headerCoverHeightConstraint
    NSLayoutConstraint.activate([
      headerCoverView.topAnchor.constraint(equalTo: topAnchor),
      headerCoverView.leadingAnchor.constraint(equalTo: leadingAnchor),
      headerCoverView.trailingAnchor.constraint(equalTo: trailingAnchor),
      headerCoverHeightConstraint,
    ])

    keyboardObserver = NotificationCenter.default.addObserver(
      forName: UIResponder.keyboardWillChangeFrameNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      self?.updateKeyboardFrame(notification)
    }
  }

  var headerInset: CGFloat = 0 {
    didSet {
      headerCoverHeightConstraint?.constant = headerInset
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    updateTerminalBottomConstraint()
  }

  private func updateKeyboardFrame(_ notification: Notification) {
    guard
      let frameValue = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue
    else {
      return
    }

    keyboardFrame = frameValue.cgRectValue
    updateTerminalBottomConstraint()

    let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue
    let curve = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue
    let options: UIView.AnimationOptions = curve.map { UIView.AnimationOptions(rawValue: $0 << 16) } ?? []
    UIView.animate(
      withDuration: duration ?? 0.25,
      delay: 0,
      options: [options, .beginFromCurrentState]
    ) { [weak self] in
      self?.layoutIfNeeded()
    }
  }

  private func updateTerminalBottomConstraint() {
    guard let keyboardFrame, window != nil else { return }
    let keyboardFrameInView = convert(keyboardFrame, from: nil)
    let keyboardOverlap = bounds.intersection(keyboardFrameInView).height
    terminalBottomConstraint?.constant = -max(0, keyboardOverlap)
  }
}
