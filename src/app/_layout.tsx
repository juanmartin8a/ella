import { DarkTheme, Stack, ThemeProvider } from 'expo-router'
import { StatusBar } from 'expo-status-bar'

import { ConnectionControllerProvider } from '../connection/ConnectionController'

export const unstable_settings = {
  anchor: 'index',
}

export default function RootLayout() {
  return (
    <ThemeProvider value={DarkTheme}>
      <ConnectionControllerProvider>
        <Stack>
          <Stack.Screen
            name="index"
            options={{ title: 'Ella', contentStyle: { paddingBottom: 0 } }}
          />
          <Stack.Screen
            name="connect"
            options={{
              presentation: 'modal',
              title: 'Connect',
              headerTransparent: true,
              headerShadowVisible: true,
            }}
          />
        </Stack>
        <StatusBar style="light" />
      </ConnectionControllerProvider>
    </ThemeProvider>
  )
}
