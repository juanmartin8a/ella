import type {
  HybridView,
  HybridViewMethods,
  HybridViewProps,
} from 'react-native-nitro-modules'

export interface EllaTerminalViewProps extends HybridViewProps {}

export interface EllaTerminalViewMethods extends HybridViewMethods {}

export type EllaTerminalView = HybridView<
  EllaTerminalViewProps,
  EllaTerminalViewMethods,
  { ios: 'swift'; android: 'kotlin' }
>
