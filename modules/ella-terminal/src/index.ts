import { getHostComponent } from 'react-native-nitro-modules'

import EllaTerminalViewConfig from '../nitrogen/generated/shared/json/EllaTerminalViewConfig.json'
import type {
  EllaTerminalViewMethods,
  EllaTerminalViewProps,
} from './EllaTerminalView.nitro'

export const EllaTerminal = getHostComponent<
  EllaTerminalViewProps,
  EllaTerminalViewMethods
>('EllaTerminalView', () => EllaTerminalViewConfig)

export type { EllaTerminalViewMethods, EllaTerminalViewProps }
