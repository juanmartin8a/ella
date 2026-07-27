import PlugConnectIcon from '@expo/material-symbols/plug_connect.xml'
import PowerIcon from '@expo/material-symbols/power_settings_new.xml'
import { DarkTheme, router, Stack, ThemeProvider } from 'expo-router'
import { StatusBar } from 'expo-status-bar'
import { SymbolView } from 'expo-symbols'
import {
  Image,
  Platform,
  Pressable,
  StyleSheet,
  type ImageSourcePropType,
} from 'react-native'
import { KeyboardProvider } from 'react-native-keyboard-controller'

import { ConnectionControllerProvider, useConnectionController } from '../connection/ConnectionController'

export const unstable_settings = {
  anchor: 'index',
}

function RootStack() {
  const controller = useConnectionController()
  const transitioning = [
    'connecting',
    'awaitingHostKey',
    'authenticating',
    'disconnecting',
  ].includes(controller.state)
  const connected = controller.state === 'connected'
  const icon =
    Platform.OS === 'ios'
      ? connected
        ? ('power' as const)
        : ('network' as const)
      : connected
        ? PowerIcon
        : PlugConnectIcon
  const disabled = transitioning || (!connected && !controller.viewReady)

  return (
    <Stack>
      <Stack.Screen
        name="index"
        options={{
          title: 'ella',
          contentStyle: {
            paddingBottom: 0,
          },
          // headerTransparent: true,
          // headerShadowVisible: true,
          // headerBlurEffect: 'systemUltraThinMaterialDark',
        }}
      />
      <Stack.Screen
        name="connect"
        options={{
          presentation: 'formSheet',
          headerShown: false,
          sheetAllowedDetents: 'fitToContents',
          // sheetGrabberVisible: true,
        }}
      />
    </Stack>
  )
}

const styles = StyleSheet.create({
  headerButton: {
    // width: 44,
    // height: 44,
    alignItems: 'center',
    justifyContent: 'center',
  },
  headerButtonDisabled: {
    opacity: 0.38,
  },
  headerButtonPressed: {
    opacity: 0.6,
  },
  headerIcon: {
    width: 24,
    height: 24,
  },
})

export default function RootLayout() {
  return (
    <KeyboardProvider>
      <ThemeProvider value={DarkTheme}>
        <ConnectionControllerProvider>
          <RootStack />
          <StatusBar style="light" />
        </ConnectionControllerProvider>
      </ThemeProvider>
    </KeyboardProvider>
  )
}
