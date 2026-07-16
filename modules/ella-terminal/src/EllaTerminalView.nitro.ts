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
  onConnectionStateChange?: (event: ConnectionStateEvent) => void
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
}

export type EllaTerminalView = HybridView<
  EllaTerminalViewProps,
  EllaTerminalViewMethods,
  { ios: 'swift'; android: 'kotlin' }
>
