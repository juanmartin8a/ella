import { callback, getHostComponent } from 'react-native-nitro-modules'
import type { ViewProps } from 'react-native'

import EllaTerminalViewConfig from '../nitrogen/generated/shared/json/EllaTerminalViewConfig.json'
import type {
  ConnectionStateEvent,
  EllaTerminalView,
  EllaTerminalViewMethods,
  EllaTerminalViewProps,
  HostKeyRequestEvent,
  TerminalKey,
} from './EllaTerminalView.nitro'

const EllaTerminalHost = getHostComponent<
  EllaTerminalViewProps,
  EllaTerminalViewMethods
>('EllaTerminalView', () => EllaTerminalViewConfig)

export interface EllaTerminalProps extends ViewProps {
  headerInset: number
  hybridRef?: (ref: EllaTerminalView) => void
  onConnectionStateChange?: (event: ConnectionStateEvent) => void
  onControlModifierChange?: (active: boolean) => void
  onHostKeyRequest?: (event: HostKeyRequestEvent) => void
}

export function EllaTerminal({
  headerInset,
  hybridRef,
  onConnectionStateChange,
  onControlModifierChange,
  onHostKeyRequest,
  ...viewProps
}: EllaTerminalProps) {
  return (
    <EllaTerminalHost
      {...viewProps}
      headerInset={headerInset}
      hybridRef={callback(hybridRef)}
      onConnectionStateChange={callback(onConnectionStateChange)}
      onControlModifierChange={callback(onControlModifierChange)}
      onHostKeyRequest={callback(onHostKeyRequest)}
    />
  )
}

export type {
  ConnectionConfig,
  ConnectionState,
  ConnectionStateEvent,
  EllaTerminalView,
  EllaTerminalViewMethods,
  EllaTerminalViewProps,
  HostKeyRequestEvent,
  TerminalKey,
  TerminalErrorCode,
  TrustedHostKey,
} from './EllaTerminalView.nitro'
