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

  var view: UIView { containerView }

  override init() {
    super.init()

    terminalView.terminalDelegate = self
    terminalView.nativeBackgroundColor = .black
    terminalView.nativeForegroundColor = .white
    terminalView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
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
  func install(_ terminalView: UIView) {
    terminalView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(terminalView)
    NSLayoutConstraint.activate([
      terminalView.topAnchor.constraint(equalTo: topAnchor),
      terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
      terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
      terminalView.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
    ])
  }
}
