import type {
  HybridView,
  HybridViewMethods,
  HybridViewProps,
} from 'react-native-nitro-modules'

export type ConnectionState =
  | 'idle'
  | 'connecting'
  | 'awaitingHostKey'
  | 'authenticating'
  | 'connected'
  | 'disconnecting'
  | 'disconnected'
  | 'error'

export type TerminalErrorCode =
  | 'connectionTimeout'
  | 'connectionRefused'
  | 'hostKeyRejected'
  | 'hostKeyTimeout'
  | 'hostKeyMismatch'
  | 'authUnsupported'
  | 'authenticationFailed'
  | 'ptyFailed'
  | 'remoteClosed'
  | 'cancelled'
  | 'internalError'

export type TerminalKey =
  | 'escape'
  | 'tab'
  | 'left'
  | 'up'
  | 'down'
  | 'right'

export interface TrustedHostKey {
  algorithm: string
  fingerprint: string
}

export interface ConnectionConfig {
  connectionId: string
  host: string
  port: number
  username: string
  password: string
  trustedHostKey?: TrustedHostKey
}

export interface ConnectionStateEvent {
  connectionId: string
  state: ConnectionState
  errorCode?: TerminalErrorCode
  message?: string
}

export interface HostKeyRequestEvent {
  connectionId: string
  requestId: string
  host: string
  port: number
  algorithm: string
  fingerprint: string
}

export interface EllaTerminalViewProps extends HybridViewProps {
  headerInset: number
  onConnectionStateChange?: (event: ConnectionStateEvent) => void
  onControlModifierChange?: (active: boolean) => void
  onHostKeyRequest?: (event: HostKeyRequestEvent) => void
}

export interface EllaTerminalViewMethods extends HybridViewMethods {
  connect(config: ConnectionConfig): void
  disconnect(connectionId: string): void
  respondToHostKey(
    connectionId: string,
    requestId: string,
    accepted: boolean
  ): void
  sendKey(key: TerminalKey): void
  setControlModifier(active: boolean): void
  showKeyboard(): void
  hideKeyboard(): void
}

export type EllaTerminalView = HybridView<
  EllaTerminalViewProps,
  EllaTerminalViewMethods,
  { ios: 'swift'; android: 'kotlin' }
>
