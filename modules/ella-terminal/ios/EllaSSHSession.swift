import CryptoKit
import Darwin
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import SwiftTerm

struct EllaTerminalSize {
  let columns: Int
  let rows: Int
  let pixelWidth: Int
  let pixelHeight: Int
}

struct EllaSSHConnectionConfiguration {
  let connectionId: String
  let host: String
  let port: Int
  let username: String
  let password: String
  let trustedAlgorithm: String?
  let trustedFingerprint: String?

  init(_ config: ConnectionConfig) throws {
    guard
      !config.connectionId.isEmpty,
      !config.host.isEmpty,
      !config.username.isEmpty,
      config.port.isFinite,
      config.port.rounded() == config.port,
      config.port >= 1,
      config.port <= 65_535
    else {
      throw EllaSSHFailure.invalidConfiguration
    }
    let port = Int(config.port)

    connectionId = config.connectionId
    host = config.host
    self.port = port
    username = config.username
    password = config.password
    trustedAlgorithm = config.trustedHostKey?.algorithm
    trustedFingerprint = config.trustedHostKey?.fingerprint
  }
}

private enum EllaSSHFailure: Error {
  case invalidConfiguration
  case connectionTimeout
  case connectionRefused
  case hostKeyRejected
  case hostKeyTimeout
  case hostKeyMismatch
  case authUnsupported
  case authenticationFailed
  case ptyFailed
  case remoteClosed
  case cancelled
  case internalError

  var terminalCode: TerminalErrorCode {
    switch self {
    case .connectionTimeout: return .connectiontimeout
    case .connectionRefused: return .connectionrefused
    case .hostKeyRejected: return .hostkeyrejected
    case .hostKeyTimeout: return .hostkeytimeout
    case .hostKeyMismatch: return .hostkeymismatch
    case .authUnsupported: return .authunsupported
    case .authenticationFailed: return .authenticationfailed
    case .ptyFailed: return .ptyfailed
    case .remoteClosed: return .remoteclosed
    case .cancelled: return .cancelled
    case .invalidConfiguration, .internalError: return .internalerror
    }
  }

  var stableMessage: String {
    switch self {
    case .invalidConfiguration: return "Invalid SSH connection configuration."
    case .connectionTimeout: return "Connection timed out."
    case .connectionRefused: return "Connection was refused."
    case .hostKeyRejected: return "Host key was rejected."
    case .hostKeyTimeout: return "Host key confirmation timed out."
    case .hostKeyMismatch: return "Host key does not match the trusted key."
    case .authUnsupported: return "The server does not support password authentication."
    case .authenticationFailed: return "Authentication failed."
    case .ptyFailed: return "Remote terminal setup failed."
    case .remoteClosed: return "Remote session closed."
    case .cancelled: return "Connection cancelled."
    case .internalError: return "SSH session failed."
    }
  }
}

extension EllaSSHFailure: LocalizedError {
  var errorDescription: String? { stableMessage }
}

final class EllaSSHSession {
  let connectionId: String

  private let host: String
  private let port: Int
  private let trustedAlgorithm: String?
  private let trustedFingerprint: String?
  private var username: String?
  private var password: String?
  private let initialSize: EllaTerminalSize
  private let group: MultiThreadedEventLoopGroup
  private let eventLoop: EventLoop
  private let onState: (ConnectionState, TerminalErrorCode?, String?) -> Void
  private let onHostKey: (String, String, String) -> Void
  private let onStopped: () -> Void
  private var outputPump: EllaTerminalOutputPump!

  private var parentChannel: Channel?
  private var childChannel: Channel?
  private var sshHandler: NIOSSHHandler?
  private var connectCompleted = false
  private var authenticated = false
  private var connected = false
  private var finishing = false
  private var shutdownStarted = false
  private var userCancelled = false
  private var shouldEmitCancellationState = false
  private var lifetimeRetainer: EllaSSHSession?
  private var pendingHostKey: PendingHostKey?
  private var latestSize: EllaTerminalSize?
  private var resizeTask: Scheduled<Void>?
  private var authenticationTimeout: Scheduled<Void>?
  private var stopCompletions: [() -> Void] = []

  private struct PendingHostKey {
    let requestId: String
    let promise: EventLoopPromise<Void>
    let timeout: Scheduled<Void>
  }

  init(
    configuration: EllaSSHConnectionConfiguration,
    initialSize: EllaTerminalSize,
    terminalView: TerminalView,
    onState: @escaping (ConnectionState, TerminalErrorCode?, String?) -> Void,
    onHostKey: @escaping (String, String, String) -> Void,
    onStopped: @escaping () -> Void
  ) {
    self.connectionId = configuration.connectionId
    self.host = configuration.host
    self.port = configuration.port
    self.trustedAlgorithm = configuration.trustedAlgorithm
    self.trustedFingerprint = configuration.trustedFingerprint
    self.username = configuration.username
    self.password = configuration.password
    self.initialSize = initialSize
    self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    self.eventLoop = group.next()
    self.onState = onState
    self.onHostKey = onHostKey
    self.onStopped = onStopped

    self.outputPump = EllaTerminalOutputPump(terminalView: terminalView) { [weak self] in
      self?.eventLoop.execute {
        self?.finish(with: .internalError)
      }
    }
  }

  func start() {
    lifetimeRetainer = self
    onState(.connecting, nil, nil)
    eventLoop.execute { [weak self] in
      self?.beginConnect()
    }
  }

  func send(_ bytes: ArraySlice<UInt8>) {
    guard !bytes.isEmpty else { return }
    let copy = Array(bytes)
    eventLoop.execute { [weak self] in
      guard let self, self.connected, !self.finishing, let channel = self.childChannel else { return }
      var buffer = channel.allocator.buffer(capacity: copy.count)
      buffer.writeBytes(copy)
      channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)), promise: nil)
    }
  }

  func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
    guard columns > 0, rows > 0 else { return }
    let size = EllaTerminalSize(
      columns: columns,
      rows: rows,
      pixelWidth: max(pixelWidth, 0),
      pixelHeight: max(pixelHeight, 0)
    )
    eventLoop.execute { [weak self] in
      guard let self, !self.finishing else { return }
      self.latestSize = size
      guard self.connected else { return }
      self.resizeTask?.cancel()
      self.resizeTask = self.eventLoop.scheduleTask(in: .milliseconds(50)) { [weak self] in
        self?.flushResize()
      }
    }
  }

  func respondToHostKey(requestId: String, accepted: Bool) {
    eventLoop.execute { [weak self] in
      guard
        let self,
        !self.finishing,
        let pending = self.pendingHostKey,
        pending.requestId == requestId
      else { return }

      self.pendingHostKey = nil
      pending.timeout.cancel()
      if accepted {
        pending.promise.succeed(())
        self.emitAuthenticating()
      } else {
        pending.promise.fail(EllaSSHFailure.hostKeyRejected)
        self.finish(with: .hostKeyRejected)
      }
    }
  }

  func disconnect() {
    eventLoop.execute { [weak self] in
      guard let self, !self.finishing else { return }
      self.userCancelled = true
      self.onState(.disconnecting, nil, nil)
      self.finish(with: .cancelled)
    }
  }

  func dispose(completion: (() -> Void)? = nil) {
    eventLoop.execute { [weak self] in
      guard let self else {
        completion?()
        return
      }
      if let completion {
        self.stopCompletions.append(completion)
      }
      guard !self.finishing else { return }
      self.userCancelled = true
      self.finish(with: .cancelled, emitState: false)
    }
  }

  private func beginConnect() {
    guard let username, let password else {
      finish(with: .internalError)
      return
    }
    self.username = nil
    self.password = nil
    armAuthenticationTimeout()

    let bootstrap = ClientBootstrap(group: group)
      .connectTimeout(.seconds(15))
      .channelOption(.tcpOption(.tcp_nodelay), value: 1)
      .channelOption(.socketOption(.so_keepalive), value: 1)
      .channelInitializer { [weak self] channel in
        guard let self else { return channel.eventLoop.makeFailedFuture(EllaSSHFailure.cancelled) }
        let userAuth = EllaPasswordAuthenticationDelegate(
          username: username,
          password: password
        )
        let hostAuth = EllaHostKeyAuthenticationDelegate(
          validator: { [weak self] algorithm, fingerprint, promise in
            guard let self else {
              promise.fail(EllaSSHFailure.cancelled)
              return
            }
            self.validateHostKey(algorithm: algorithm, fingerprint: fingerprint, promise: promise)
          }
        )
        let sshHandler = NIOSSHHandler(
          role: .client(
            .init(userAuthDelegate: userAuth, serverAuthDelegate: hostAuth)
          ),
          allocator: channel.allocator,
          inboundChildChannelInitializer: nil
        )
        return channel.eventLoop.makeCompletedFuture {
          let pipeline = channel.pipeline.syncOperations
          try pipeline.addHandler(
            EllaSSHTransportMonitor { [weak self] event in self?.handleTransportEvent(event) }
          )
          try pipeline.addHandler(sshHandler)
          try pipeline.addHandler(
            EllaSSHAuthenticationMonitor { [weak self] event in
              self?.handleAuthenticationEvent(event, sshHandler: sshHandler)
            }
          )
        }
      }

    bootstrap.connect(host: host, port: port).whenComplete { [weak self] result in
      guard let self else { return }
      self.connectCompleted = true
      switch result {
      case .success(let channel):
        self.parentChannel = channel
        channel.closeFuture.whenComplete { [weak self] _ in
          guard let self else { return }
          if !self.finishing {
            self.finish(with: .remoteClosed)
          }
          self.shutdownEventLoopGroup()
        }
        if self.finishing {
          channel.close(promise: nil)
        }
      case .failure(let error):
        if !self.finishing {
          self.finish(with: self.classify(error))
        } else {
          self.shutdownEventLoopGroup()
        }
      }
    }
  }

  private func validateHostKey(
    algorithm: String,
    fingerprint: String,
    promise: EventLoopPromise<Void>
  ) {
    eventLoop.assertInEventLoop()
    guard !finishing, pendingHostKey == nil else {
      promise.fail(EllaSSHFailure.cancelled)
      return
    }

    if let trustedAlgorithm, let trustedFingerprint {
      guard algorithm == trustedAlgorithm, fingerprint == trustedFingerprint else {
        promise.fail(EllaSSHFailure.hostKeyMismatch)
        finish(with: .hostKeyMismatch)
        return
      }
      promise.succeed(())
      emitAuthenticating()
      armAuthenticationTimeout()
      return
    }

    let requestId = UUID().uuidString
    authenticationTimeout?.cancel()
    authenticationTimeout = nil
    let timeout = eventLoop.scheduleTask(in: .seconds(60)) { [weak self] in
      guard let self, let pending = self.pendingHostKey, pending.requestId == requestId else { return }
      self.pendingHostKey = nil
      pending.promise.fail(EllaSSHFailure.hostKeyTimeout)
      self.finish(with: .hostKeyTimeout)
    }
    pendingHostKey = PendingHostKey(requestId: requestId, promise: promise, timeout: timeout)
    onState(.awaitinghostkey, nil, nil)
    onHostKey(requestId, algorithm, fingerprint)
  }

  private func emitAuthenticating() {
    guard !authenticated, !finishing else { return }
    authenticated = true
    onState(.authenticating, nil, nil)
    armAuthenticationTimeout()
  }

  private func handleTransportEvent(_ event: EllaSSHTransportEvent) {
    eventLoop.assertInEventLoop()
    switch event {
    case .inactive:
      if !finishing { finish(with: .remoteClosed) }
    case .error(let error):
      if !finishing { finish(with: classify(error)) }
    }
  }

  private func handleAuthenticationEvent(
    _ event: EllaSSHAuthenticationEvent,
    sshHandler: NIOSSHHandler
  ) {
    eventLoop.assertInEventLoop()
    switch event {
    case .authenticated:
      authenticationTimeout?.cancel()
      authenticationTimeout = nil
      self.sshHandler = sshHandler
      openSessionChannel()
    case .error(let error):
      if !finishing { finish(with: classify(error)) }
    }
  }

  private func openSessionChannel() {
    guard !finishing, childChannel == nil, let sshHandler else { return }
    let requestedSize = latestSize ?? initialSize
    latestSize = nil

    let promise = eventLoop.makePromise(of: Channel.self)
    sshHandler.createChannel(promise, channelType: .session) { [weak self] child, channelType in
      guard let self, !self.finishing, channelType == .session else {
        return child.eventLoop.makeFailedFuture(EllaSSHFailure.cancelled)
      }
      self.childChannel = child
      let handler = EllaSSHShellHandler(
        initialSize: requestedSize,
        onData: { [weak self] bytes in self?.outputPump.enqueue(bytes) },
        onSetup: { [weak self] result in self?.handleShellSetup(result) },
        onClosed: { [weak self] in
          guard let self, !self.finishing else { return }
          self.finish(with: .remoteClosed)
        }
      )
      return child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
        child.pipeline.addHandler(handler)
      }
    }

    promise.futureResult.whenFailure { [weak self] error in
      guard let self, !self.finishing else { return }
      self.finish(with: self.classify(error, setup: true))
    }
  }

  private func handleShellSetup(_ result: Result<Void, Error>) {
    eventLoop.assertInEventLoop()
    guard !finishing else { return }
    switch result {
    case .success:
      guard !connected else { return }
      connected = true
      onState(.connected, nil, nil)
      flushResize()
    case .failure:
      finish(with: .ptyFailed)
    }
  }

  private func flushResize() {
    eventLoop.assertInEventLoop()
    resizeTask = nil
    guard connected, !finishing, let size = latestSize, let childChannel else { return }
    latestSize = nil
    childChannel.triggerUserOutboundEvent(
      SSHChannelRequestEvent.WindowChangeRequest(
        terminalCharacterWidth: size.columns,
        terminalRowHeight: size.rows,
        terminalPixelWidth: size.pixelWidth,
        terminalPixelHeight: size.pixelHeight
      ),
      promise: nil
    )
  }

  private func finish(with failure: EllaSSHFailure, emitState: Bool = true) {
    eventLoop.assertInEventLoop()
    guard !finishing else { return }
    finishing = true
    shouldEmitCancellationState = emitState && userCancelled

    resizeTask?.cancel()
    resizeTask = nil
    authenticationTimeout?.cancel()
    authenticationTimeout = nil
    if let pending = pendingHostKey {
      pendingHostKey = nil
      pending.timeout.cancel()
      pending.promise.fail(failure)
    }
    outputPump.invalidate()

    if emitState {
      if userCancelled {
        // The final disconnected event is emitted after the event-loop thread is gone.
      } else {
        onState(.error, failure.terminalCode, failure.stableMessage)
      }
    }

    childChannel?.close(promise: nil)
    if let parentChannel {
      parentChannel.close(promise: nil)
    } else if connectCompleted {
      shutdownEventLoopGroup()
    }
  }

  private func shutdownEventLoopGroup() {
    eventLoop.assertInEventLoop()
    guard !shutdownStarted else { return }
    shutdownStarted = true
    parentChannel = nil
    childChannel = nil
    sshHandler = nil

    DispatchQueue.global(qos: .utility).async { [group, weak self] in
      group.shutdownGracefully(queue: .global(qos: .utility)) { _ in
        guard let self else { return }
        if self.shouldEmitCancellationState {
          self.onState(.disconnected, .cancelled, EllaSSHFailure.cancelled.stableMessage)
        }
        let completions = self.stopCompletions
        self.stopCompletions.removeAll(keepingCapacity: false)
        for completion in completions { completion() }
        self.onStopped()
        self.lifetimeRetainer = nil
      }
    }
  }

  private func classify(_ error: Error, setup: Bool = false) -> EllaSSHFailure {
    if let failure = error as? EllaSSHFailure { return failure }
    if let channelError = error as? ChannelError,
       case .connectTimeout = channelError {
      return .connectionTimeout
    }
    if let ioError = error as? IOError, ioError.errnoCode == ECONNREFUSED {
      return .connectionRefused
    }
    if setup { return .ptyFailed }
    if connected { return .remoteClosed }
    return .internalError
  }

  private func armAuthenticationTimeout() {
    authenticationTimeout?.cancel()
    authenticationTimeout = eventLoop.scheduleTask(in: .seconds(15)) { [weak self] in
      guard let self, !self.finishing else { return }
      self.finish(with: .connectionTimeout)
    }
  }
}

private final class EllaPasswordAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate {
  private var username: String?
  private var password: String?
  private var attempted = false

  init(username: String, password: String) {
    self.username = username
    self.password = password
  }

  func nextAuthenticationType(
    availableMethods: NIOSSHAvailableUserAuthenticationMethods,
    nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
  ) {
    guard availableMethods.contains(.password) else {
      username = nil
      password = nil
      nextChallengePromise.fail(EllaSSHFailure.authUnsupported)
      return
    }
    guard !attempted, let username, let password else {
      self.username = nil
      self.password = nil
      nextChallengePromise.fail(EllaSSHFailure.authenticationFailed)
      return
    }

    attempted = true
    self.username = nil
    self.password = nil
    nextChallengePromise.succeed(
      NIOSSHUserAuthenticationOffer(
        username: username,
        serviceName: "",
        offer: .password(.init(password: password))
      )
    )
  }
}

private final class EllaHostKeyAuthenticationDelegate: NIOSSHClientServerAuthenticationDelegate {
  private let validator: (String, String, EventLoopPromise<Void>) -> Void

  init(
    validator: @escaping (String, String, EventLoopPromise<Void>) -> Void
  ) {
    self.validator = validator
  }

  func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
    let fields = String(openSSHPublicKey: hostKey).split(
      separator: " ",
      maxSplits: 2,
      omittingEmptySubsequences: true
    )
    guard fields.count >= 2, let wireBlob = Data(base64Encoded: String(fields[1])) else {
      validationCompletePromise.fail(EllaSSHFailure.internalError)
      return
    }

    let digest = SHA256.hash(data: wireBlob)
    let encoded = Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
    validator(String(fields[0]), "SHA256:\(encoded)", validationCompletePromise)
  }
}

private enum EllaSSHTransportEvent {
  case inactive
  case error(Error)
}

private final class EllaSSHTransportMonitor: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer
  private let callback: (EllaSSHTransportEvent) -> Void

  init(callback: @escaping (EllaSSHTransportEvent) -> Void) {
    self.callback = callback
  }

  func channelInactive(context: ChannelHandlerContext) {
    callback(.inactive)
    context.fireChannelInactive()
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    callback(.error(error))
    context.fireErrorCaught(error)
  }
}

private enum EllaSSHAuthenticationEvent {
  case authenticated
  case error(Error)
}

private final class EllaSSHAuthenticationMonitor: ChannelInboundHandler {
  typealias InboundIn = Never
  private let callback: (EllaSSHAuthenticationEvent) -> Void

  init(callback: @escaping (EllaSSHAuthenticationEvent) -> Void) {
    self.callback = callback
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if event is UserAuthSuccessEvent {
      callback(.authenticated)
    }
    context.fireUserInboundEventTriggered(event)
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    callback(.error(error))
    context.close(promise: nil)
  }
}

private final class EllaSSHShellHandler: ChannelInboundHandler {
  typealias InboundIn = SSHChannelData

  private let initialSize: EllaTerminalSize
  private let onData: ([UInt8]) -> Void
  private let onSetup: (Result<Void, Error>) -> Void
  private let onClosed: () -> Void
  private var pendingReply: EventLoopPromise<Void>?
  private var pendingReplyTimeout: Scheduled<Void>?
  private var setupReported = false
  private var closureReported = false

  init(
    initialSize: EllaTerminalSize,
    onData: @escaping ([UInt8]) -> Void,
    onSetup: @escaping (Result<Void, Error>) -> Void,
    onClosed: @escaping () -> Void
  ) {
    self.initialSize = initialSize
    self.onData = onData
    self.onSetup = onSetup
    self.onClosed = onClosed
  }

  func channelActive(context: ChannelHandlerContext) {
    request(
      SSHChannelRequestEvent.PseudoTerminalRequest(
        wantReply: true,
        term: "xterm-256color",
        terminalCharacterWidth: initialSize.columns,
        terminalRowHeight: initialSize.rows,
        terminalPixelWidth: initialSize.pixelWidth,
        terminalPixelHeight: initialSize.pixelHeight,
        terminalModes: SSHTerminalModes([:])
      ),
      context: context
    ).flatMap { [weak self] in
      guard let self else { return context.eventLoop.makeFailedFuture(EllaSSHFailure.cancelled) }
      context.triggerUserOutboundEvent(
        SSHChannelRequestEvent.EnvironmentRequest(
          wantReply: false,
          name: "LANG",
          value: "en_US.UTF-8"
        ),
        promise: nil
      )
      return self.request(SSHChannelRequestEvent.ShellRequest(wantReply: true), context: context)
    }.whenComplete { [weak self] result in
      self?.reportSetup(result)
    }

    context.fireChannelActive()
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let payload = unwrapInboundIn(data)
    guard payload.type == .channel || payload.type == .stdErr else { return }
    guard case .byteBuffer(let buffer) = payload.data, !buffer.readableBytesView.isEmpty else { return }
    onData(Array(buffer.readableBytesView))
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if event is ChannelSuccessEvent {
      pendingReplyTimeout?.cancel()
      pendingReplyTimeout = nil
      let reply = pendingReply
      pendingReply = nil
      reply?.succeed(())
      return
    }
    if event is ChannelFailureEvent {
      failPending(EllaSSHFailure.ptyFailed)
      return
    }
    if event is SSHChannelRequestEvent.ExitStatus || event is SSHChannelRequestEvent.ExitSignal {
      reportClosed()
      context.close(promise: nil)
      return
    }
    if let channelEvent = event as? ChannelEvent, channelEvent == .inputClosed {
      reportClosed()
      context.close(promise: nil)
      return
    }
    context.fireUserInboundEventTriggered(event)
  }

  func channelInactive(context: ChannelHandlerContext) {
    failPending(EllaSSHFailure.remoteClosed)
    reportClosed()
    context.fireChannelInactive()
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    failPending(error)
    reportClosed()
    context.close(promise: nil)
  }

  func handlerRemoved(context: ChannelHandlerContext) {
    failPending(EllaSSHFailure.cancelled)
  }

  private func request(_ event: Any, context: ChannelHandlerContext) -> EventLoopFuture<Void> {
    precondition(pendingReply == nil)
    let response = context.eventLoop.makePromise(of: Void.self)
    let write = context.eventLoop.makePromise(of: Void.self)
    pendingReply = response
    pendingReplyTimeout = context.eventLoop.scheduleTask(in: .seconds(15)) { [weak self] in
      self?.failPending(EllaSSHFailure.ptyFailed)
    }
    write.futureResult.whenFailure { [weak self] error in
      self?.failPending(error)
    }
    context.triggerUserOutboundEvent(event, promise: write)
    return response.futureResult
  }

  private func failPending(_ error: Error) {
    pendingReplyTimeout?.cancel()
    pendingReplyTimeout = nil
    let reply = pendingReply
    pendingReply = nil
    reply?.fail(error)
  }

  private func reportSetup(_ result: Result<Void, Error>) {
    guard !setupReported else { return }
    setupReported = true
    onSetup(result)
  }

  private func reportClosed() {
    guard !closureReported else { return }
    closureReported = true
    onClosed()
  }
}
