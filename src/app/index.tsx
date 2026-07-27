import PlugConnectIcon from '@expo/material-symbols/plug_connect.xml'
import PowerIcon from '@expo/material-symbols/power_settings_new.xml'
import { EllaTerminal } from 'ella-terminal'
import { router, Stack } from 'expo-router'
import { useHeaderHeight } from 'expo-router/react-navigation'
import { InputAccessoryView, Platform, StyleSheet, View } from 'react-native'

import { TerminalExtraKeys } from '../components/TerminalExtraKeys'
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
      <View style={styles.terminalArea}>

        <EllaTerminal
          headerInset={0.0}
          hybridRef={controller.hybridRef}
          onConnectionStateChange={controller.onConnectionStateChange}
          onControlModifierChange={controller.onControlModifierChange}
          onHostKeyRequest={controller.onHostKeyRequest}
          style={styles.terminal}
        />
        {Platform.OS === 'android' && (
          <TerminalExtraKeys
            controlModifierActive={controller.controlModifierActive}
            disabled={!connected}
            onHideKeyboard={controller.hideKeyboard}
            onSendKey={controller.sendKey}
            onShowKeyboard={controller.showKeyboard}
            onToggleControlModifier={controller.toggleControlModifier}
          />
        )}
        {Platform.OS === 'ios' && (
          <InputAccessoryView
            backgroundColor="transparent"
            nativeID="ella-terminal-extra-keys"
          >
            <TerminalExtraKeys
              controlModifierActive={controller.controlModifierActive}
              disabled={!connected}
              onHideKeyboard={controller.hideKeyboard}
              onSendKey={controller.sendKey}
              onShowKeyboard={controller.showKeyboard}
              onToggleControlModifier={controller.toggleControlModifier}
            />
          </InputAccessoryView>
        )}
      </View>
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
  terminalArea: {
    flex: 1,
  },
})
