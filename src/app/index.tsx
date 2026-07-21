import PlugConnectIcon from '@expo/material-symbols/plug_connect.xml'
import PowerIcon from '@expo/material-symbols/power_settings_new.xml'
import { EllaTerminal } from 'ella-terminal'
import { router, Stack } from 'expo-router'
import { useHeaderHeight } from 'expo-router/react-navigation'
import { Platform, StyleSheet, View } from 'react-native'

import { useConnectionController } from '../connection/ConnectionController'

const stateTitles = {
  idle: 'Ella',
  connecting: 'Ella - Connecting',
  awaitingHostKey: 'Ella - Verify host',
  authenticating: 'Ella - Authenticating',
  connected: 'Ella - Connected',
  disconnecting: 'Ella - Disconnecting',
  disconnected: 'Ella',
  error: 'Ella',
} as const

export default function TerminalScreen() {
  const controller = useConnectionController()
  const headerInset = useHeaderHeight()
  const transitioning = [
    'connecting',
    'awaitingHostKey',
    'authenticating',
    'disconnecting',
  ].includes(controller.state)
  const connected = controller.state === 'connected'
  const title = controller.connectionHost ?? stateTitles[controller.state]
  const icon =
    Platform.OS === 'ios'
      ? connected
        ? ('power' as const)
        : ('network' as const)
      : connected
        ? PowerIcon
        : PlugConnectIcon

  return (
    <View style={styles.container}>
      <Stack.Header
        transparent
      />
      <Stack.Title>{title}</Stack.Title>
      <Stack.Toolbar placement="right">
        <Stack.Toolbar.Button
          accessibilityLabel={connected ? 'Disconnect' : 'Connect'}
          disabled={transitioning || (!connected && !controller.viewReady)}
          icon={icon}
          onPress={connected ? controller.disconnect : () => router.push('/connect')}
        >
          {connected ? 'Disconnect' : 'Connect'}
        </Stack.Toolbar.Button>
      </Stack.Toolbar>
      <EllaTerminal
        headerInset={headerInset}
        hybridRef={controller.hybridRef}
        onConnectionStateChange={controller.onConnectionStateChange}
        onHostKeyRequest={controller.onHostKeyRequest}
        style={styles.terminal}
      />
    </View>
  )
}

const styles = StyleSheet.create({
  container: {
    position: 'absolute',
    top: 0,
    right: 0,
    bottom: 0,
    left: 0,
  },
  terminal: {
    flex: 1,
  },
})
