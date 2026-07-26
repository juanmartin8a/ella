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
      terminalView.topInset = CGFloat(max(0, headerInset))
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
#if DEBUG
    terminalView.logDiagnostic("resize cols=\(newCols) rows=\(newRows)")
#endif
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

#if DEBUG
  private var diagnosticLayoutSequence = 0

  override var contentOffset: CGPoint {
    didSet {
      guard oldValue != contentOffset else { return }
      logDiagnostic("offset old=\(diagnosticPoint(oldValue)) new=\(diagnosticPoint(contentOffset))")
    }
  }
#endif

  var topInset: CGFloat = 0 {
    didSet {
      viewportTopInset = max(0, topInset)
    }
  }

  override func layoutSubviews() {
#if DEBUG
    let oldBounds = bounds
    let oldRows = getTerminal().rows
    let oldYDisp = diagnosticYDisp
#endif
    super.layoutSubviews()
#if DEBUG
    if oldBounds != bounds || oldRows != getTerminal().rows || oldYDisp != diagnosticYDisp {
      diagnosticLayoutSequence += 1
      let rowChange = "rows=\(oldRows)->\(getTerminal().rows)"
      let scrollChange = "yDisp=\(oldYDisp)->\(diagnosticYDisp)"
      logDiagnostic(
        "layout#\(diagnosticLayoutSequence) oldBounds=\(diagnosticRect(oldBounds)) "
          + "\(rowChange) \(scrollChange)"
      )
    }
#endif
    guard !bounds.isEmpty, let onFirstLayout else { return }
    self.onFirstLayout = nil
    onFirstLayout()
  }

#if DEBUG
  func logDiagnostic(_ event: String) {
    let terminal = getTerminal()
    let gesture = panGestureRecognizer
    let geometry = "bounds=\(diagnosticRect(bounds)) content=\(diagnosticSize(contentSize))"
    let scrolling = "offset=\(diagnosticPoint(contentOffset)) inset=\(diagnosticInsets(adjustedContentInset))"
    let model = "cols=\(terminal.cols) rows=\(terminal.rows) yDisp=\(diagnosticYDisp) manual=\(diagnosticUserScrolling)"
    let gestureState = "tracking=\(isTracking) dragging=\(isDragging) decelerating=\(isDecelerating)"
    let input = "pan=\(diagnosticGestureState(gesture.state)) responder=\(isFirstResponder)"
    print("[EllaTerminalDiagnostics] t=\(diagnosticNumber(CACurrentMediaTime())) terminal \(event) \(geometry) \(scrolling) \(model) \(gestureState) \(input)")
  }
#endif
}

private final class KeyboardAvoidingTerminalContainer: UIView {
#if DEBUG
  private weak var diagnosticTerminalView: EllaSwiftTermView?
  private var diagnosticDisplayLink: CADisplayLink?
  private var diagnosticDisplayLinkProxy: DiagnosticDisplayLinkProxy?
  private var diagnosticObservers: [NSObjectProtocol] = []
  private var lastDiagnosticSample: DiagnosticGeometrySample?
#endif

  func install(_ terminalView: UIView) {
    terminalView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(terminalView)
    keyboardLayoutGuide.usesBottomSafeArea = false

    NSLayoutConstraint.activate([
      terminalView.topAnchor.constraint(equalTo: topAnchor),
      terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
      terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
      terminalView.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
    ])

#if DEBUG
    if let terminalView = terminalView as? EllaSwiftTermView {
      installDiagnostics(terminalView)
    }
#endif
  }

#if DEBUG
  deinit {
    stopDiagnostics()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      stopDiagnosticDisplayLink()
    } else {
      startDiagnosticDisplayLink()
    }
  }

  private func installDiagnostics(_ terminalView: EllaSwiftTermView) {
    diagnosticTerminalView = terminalView
    let center = NotificationCenter.default
    let names: [Notification.Name] = [
      UIResponder.keyboardWillShowNotification,
      UIResponder.keyboardDidShowNotification,
      UIResponder.keyboardWillChangeFrameNotification,
      UIResponder.keyboardDidChangeFrameNotification,
      UIResponder.keyboardWillHideNotification,
      UIResponder.keyboardDidHideNotification,
    ]
    diagnosticObservers = names.map { name in
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
        self?.logKeyboardNotification(notification)
      }
    }
  }

  private func startDiagnosticDisplayLink() {
    guard diagnosticDisplayLink == nil else { return }
    let proxy = DiagnosticDisplayLinkProxy { [weak self] in
      self?.sampleDiagnosticGeometry()
    }
    let displayLink = CADisplayLink(target: proxy, selector: #selector(DiagnosticDisplayLinkProxy.tick))
    displayLink.add(to: .main, forMode: .common)
    diagnosticDisplayLinkProxy = proxy
    diagnosticDisplayLink = displayLink
  }

  private func stopDiagnosticDisplayLink() {
    diagnosticDisplayLink?.invalidate()
    diagnosticDisplayLink = nil
    diagnosticDisplayLinkProxy = nil
    lastDiagnosticSample = nil
  }

  private func stopDiagnostics() {
    stopDiagnosticDisplayLink()
    let center = NotificationCenter.default
    diagnosticObservers.forEach(center.removeObserver)
    diagnosticObservers.removeAll()
  }

  private func logKeyboardNotification(_ notification: Notification) {
    let userInfo = notification.userInfo
    let beginFrame = (userInfo?[UIResponder.keyboardFrameBeginUserInfoKey] as? NSValue)?.cgRectValue
    let endFrame = (userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
    let duration = (userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue
    let curve = (userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.intValue
    let curveDescription = curve.map(String.init) ?? "nil"
    print(
      "[EllaTerminalDiagnostics] t=\(diagnosticNumber(CACurrentMediaTime())) keyboard "
        + "event=\(notification.name.rawValue) begin=\(diagnosticOptionalRect(beginFrame)) "
        + "end=\(diagnosticOptionalRect(endFrame)) duration=\(diagnosticOptionalNumber(duration)) "
        + "curve=\(curveDescription)"
    )
    sampleDiagnosticGeometry(force: true)
  }

  private func sampleDiagnosticGeometry(force: Bool = false) {
    guard let terminalView = diagnosticTerminalView, window != nil else { return }
    let accessory = terminalView.inputAccessoryView
    let accessoryModelFrame = accessory.flatMap { diagnosticFrameInContainer($0, presentation: false) }
    let accessoryPresentationFrame = accessory.flatMap { diagnosticFrameInContainer($0, presentation: true) }
    let sample = DiagnosticGeometrySample(
      guideTop: keyboardLayoutGuide.layoutFrame.minY,
      terminalBottom: terminalView.frame.maxY,
      accessoryModelTop: accessoryModelFrame?.minY,
      accessoryPresentationTop: accessoryPresentationFrame?.minY,
      accessoryHeight: accessory?.bounds.height,
      accessoryAttached: accessory?.window != nil,
      offsetY: terminalView.contentOffset.y,
      rows: terminalView.getTerminal().rows,
      yDisp: terminalView.diagnosticYDisp,
      userScrolling: terminalView.diagnosticUserScrolling,
      tracking: terminalView.isTracking,
      dragging: terminalView.isDragging,
      decelerating: terminalView.isDecelerating
    )
    guard force || sample.differs(from: lastDiagnosticSample) else { return }
    lastDiagnosticSample = sample
    let layout = "guideTop=\(diagnosticNumber(sample.guideTop)) terminalBottom=\(diagnosticNumber(sample.terminalBottom))"
    let accessoryState = "accessoryModelTop=\(diagnosticOptionalNumber(sample.accessoryModelTop)) accessoryPresentationTop=\(diagnosticOptionalNumber(sample.accessoryPresentationTop)) accessoryHeight=\(diagnosticOptionalNumber(sample.accessoryHeight)) attached=\(sample.accessoryAttached)"
    let scrollState = "offsetY=\(diagnosticNumber(sample.offsetY)) rows=\(sample.rows) yDisp=\(sample.yDisp) manual=\(sample.userScrolling)"
    let gestureState = "tracking=\(sample.tracking) dragging=\(sample.dragging) decelerating=\(sample.decelerating)"
    print("[EllaTerminalDiagnostics] t=\(diagnosticNumber(CACurrentMediaTime())) geometry \(layout) \(accessoryState) \(scrollState) \(gestureState)")
  }

  private func diagnosticFrameInContainer(_ view: UIView, presentation: Bool) -> CGRect? {
    if presentation, let presentationLayer = view.layer.presentation(), let superview = view.superview {
      let frameInScreen = superview.convert(presentationLayer.frame, to: nil)
      return convert(frameInScreen, from: nil)
    }
    return view.convert(view.bounds, to: self)
  }
#endif
}

#if DEBUG
private final class DiagnosticDisplayLinkProxy: NSObject {
  private let callback: () -> Void

  init(callback: @escaping () -> Void) {
    self.callback = callback
  }

  @objc func tick() {
    callback()
  }
}

private struct DiagnosticGeometrySample {
  let guideTop: CGFloat
  let terminalBottom: CGFloat
  let accessoryModelTop: CGFloat?
  let accessoryPresentationTop: CGFloat?
  let accessoryHeight: CGFloat?
  let accessoryAttached: Bool
  let offsetY: CGFloat
  let rows: Int
  let yDisp: Int
  let userScrolling: Bool
  let tracking: Bool
  let dragging: Bool
  let decelerating: Bool

  func differs(from other: DiagnosticGeometrySample?) -> Bool {
    guard let other else { return true }
    return diagnosticChanged(guideTop, other.guideTop)
      || diagnosticChanged(terminalBottom, other.terminalBottom)
      || diagnosticChanged(accessoryModelTop, other.accessoryModelTop)
      || diagnosticChanged(accessoryPresentationTop, other.accessoryPresentationTop)
      || diagnosticChanged(accessoryHeight, other.accessoryHeight)
      || accessoryAttached != other.accessoryAttached
      || diagnosticChanged(offsetY, other.offsetY)
      || rows != other.rows
      || yDisp != other.yDisp
      || userScrolling != other.userScrolling
      || tracking != other.tracking
      || dragging != other.dragging
      || decelerating != other.decelerating
  }
}

private func diagnosticChanged(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
  abs(lhs - rhs) >= 0.25
}

private func diagnosticChanged(_ lhs: CGFloat?, _ rhs: CGFloat?) -> Bool {
  switch (lhs, rhs) {
  case let (lhs?, rhs?):
    diagnosticChanged(lhs, rhs)
  case (nil, nil):
    false
  default:
    true
  }
}

private func diagnosticNumber<T: BinaryFloatingPoint>(_ value: T) -> String {
  String(format: "%.2f", Double(value))
}

private func diagnosticOptionalNumber<T: BinaryFloatingPoint>(_ value: T?) -> String {
  value.map(diagnosticNumber) ?? "nil"
}

private func diagnosticPoint(_ point: CGPoint) -> String {
  "(\(diagnosticNumber(point.x)),\(diagnosticNumber(point.y)))"
}

private func diagnosticSize(_ size: CGSize) -> String {
  "(\(diagnosticNumber(size.width)),\(diagnosticNumber(size.height)))"
}

private func diagnosticRect(_ rect: CGRect) -> String {
  "(\(diagnosticNumber(rect.minX)),\(diagnosticNumber(rect.minY)),"
    + "\(diagnosticNumber(rect.width)),\(diagnosticNumber(rect.height)))"
}

private func diagnosticOptionalRect(_ rect: CGRect?) -> String {
  rect.map(diagnosticRect) ?? "nil"
}

private func diagnosticInsets(_ insets: UIEdgeInsets) -> String {
  "(t:\(diagnosticNumber(insets.top)),l:\(diagnosticNumber(insets.left)),"
    + "b:\(diagnosticNumber(insets.bottom)),r:\(diagnosticNumber(insets.right)))"
}

private func diagnosticGestureState(_ state: UIGestureRecognizer.State) -> String {
  switch state {
  case .possible: "possible"
  case .began: "began"
  case .changed: "changed"
  case .ended: "ended"
  case .cancelled: "cancelled"
  case .failed: "failed"
  @unknown default: "unknown"
  }
}
#endif
