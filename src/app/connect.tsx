import { router, Stack } from 'expo-router'
import { useEffect, useState } from 'react'
import {
  Alert,
  KeyboardAvoidingView,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Switch,
  Text,
  TextInput,
  View,
} from 'react-native'

import {
  type ConnectionForm,
  useConnectionController,
} from '../connection/ConnectionController'
import { normalizeHost } from '../connection/storage'

const initialForm: ConnectionForm = {
  host: '',
  port: 22,
  username: '',
  password: '',
  savePassword: false,
}

export default function ConnectScreen() {
  const controller = useConnectionController()
  const getDefaults = controller.getDefaults
  const [form, setForm] = useState(initialForm)
  const [portText, setPortText] = useState('22')
  const [hasTrustedHostKey, setHasTrustedHostKey] = useState(false)
  const [loading, setLoading] = useState(true)
  const [submitting, setSubmitting] = useState(false)

  useEffect(() => {
    let active = true
    void getDefaults()
      .then((defaults) => {
        if (!active) return
        setForm(defaults)
        setPortText(String(defaults.port))
        setHasTrustedHostKey(defaults.hasTrustedHostKey)
      })
      .catch(() => {
        if (active) Alert.alert('Storage error', 'Could not load saved connection settings.')
      })
      .finally(() => {
        if (active) setLoading(false)
      })
    return () => {
      active = false
    }
  }, [getDefaults])

  const parsedPort = /^\d+$/.test(portText) ? Number(portText) : Number.NaN
  const valid =
    normalizeHost(form.host).length > 0 &&
    !/\s/.test(normalizeHost(form.host)) &&
    form.username.trim().length > 0 &&
    form.password.length > 0 &&
    Number.isInteger(parsedPort) &&
    parsedPort >= 1 &&
    parsedPort <= 65535
  const transitioning = [
    'connecting',
    'awaitingHostKey',
    'authenticating',
    'disconnecting',
  ].includes(controller.state)

  const refreshTrustedHostKey = async () => {
    if (!Number.isInteger(parsedPort) || parsedPort < 1 || parsedPort > 65535) {
      setHasTrustedHostKey(false)
      return
    }
    try {
      setHasTrustedHostKey(
        await controller.hasTrustedHostKey({
          host: form.host,
          port: parsedPort,
          username: form.username,
        }),
      )
    } catch {
      setHasTrustedHostKey(false)
    }
  }

  const submit = async () => {
    if (!valid || submitting) return
    setSubmitting(true)
    try {
      await controller.connect({ ...form, port: parsedPort })
      setForm((current) => ({ ...current, password: '' }))
      router.dismiss()
    } catch {
      setForm((current) => ({ ...current, password: '' }))
      Alert.alert('Connection failed', 'Could not start the SSH connection.')
    } finally {
      setSubmitting(false)
    }
  }

  const forgetHostKey = async () => {
    try {
      await controller.forgetHostKey({
        host: form.host,
        port: parsedPort,
        username: form.username,
      })
      setHasTrustedHostKey(false)
    } catch {
      Alert.alert('Storage error', 'Could not forget the trusted host key.')
    }
  }

  return (
    <KeyboardAvoidingView
      behavior={Platform.OS === 'ios' ? 'padding' : undefined}
      style={styles.screen}
    >
      <Stack.Title>Connect</Stack.Title>
      <ScrollView
        contentContainerStyle={styles.content}
        keyboardShouldPersistTaps="handled"
      >
        <View style={styles.fields}>
          <Field
            label="HOST"
            value={form.host}
            autoCapitalize="none"
            autoCorrect={false}
            placeholder="server.example.com or 2001:db8::1"
            onBlur={() => void refreshTrustedHostKey()}
            onChangeText={(host) => setForm((current) => ({ ...current, host }))}
          />
          <Field
            label="PORT"
            value={portText}
            keyboardType="number-pad"
            placeholder="22"
            onBlur={() => void refreshTrustedHostKey()}
            onChangeText={setPortText}
          />
          <Field
            label="USERNAME"
            value={form.username}
            autoCapitalize="none"
            autoCorrect={false}
            placeholder="operator"
            onChangeText={(username) =>
              setForm((current) => ({ ...current, username }))
            }
          />
          <Field
            label="PASSWORD"
            value={form.password}
            autoCapitalize="none"
            autoCorrect={false}
            secureTextEntry
            placeholder="Required"
            onChangeText={(password) =>
              setForm((current) => ({ ...current, password }))
            }
          />
        </View>

        <View style={styles.switchRow}>
          <View style={styles.switchCopy}>
            <Text style={styles.switchTitle}>Save password</Text>
            <Text style={styles.switchCaption}>This device only on iOS</Text>
          </View>
          <Switch
            style={styles.switch}
            value={form.savePassword}
            onValueChange={(savePassword) =>
              setForm((current) => ({ ...current, savePassword }))
            }
          />
        </View>

        {hasTrustedHostKey ? (
          <Pressable
            accessibilityRole="button"
            onPress={() => void forgetHostKey()}
            style={styles.forgetButton}
          >
            <Text style={styles.forgetText}>Forget Host Key</Text>
          </Pressable>
        ) : null}

        <Pressable
          accessibilityRole="button"
          disabled={
            !valid ||
            loading ||
            submitting ||
            transitioning ||
            !controller.viewReady
          }
          onPress={() => void submit()}
          style={({ pressed }) => [
            styles.connectButton,
            (!valid || loading || submitting || transitioning || !controller.viewReady) &&
              styles.connectButtonDisabled,
            pressed && styles.connectButtonPressed,
          ]}
        >
          <Text style={styles.connectText}>
            {submitting ? 'STARTING...' : 'CONNECT'}
          </Text>
        </Pressable>
      </ScrollView>
    </KeyboardAvoidingView>
  )
}

interface FieldProps extends React.ComponentProps<typeof TextInput> {
  label: string
}

function Field({ label, ...inputProps }: FieldProps) {
  return (
    <View style={styles.field}>
      <Text style={styles.label}>{label}</Text>
      <TextInput
        {...inputProps}
        placeholderTextColor="#5f6672"
        selectionColor="#81d4a3"
        underlineColorAndroid="transparent"
        style={styles.input}
      />
    </View>
  )
}

const styles = StyleSheet.create({
  screen: {
    flex: 1,
    backgroundColor: '#090a0c',
  },
  content: {
    padding: 22,
    paddingTop: Platform.select({ ios: 88, android: 72 }),
    paddingBottom: 44,
    gap: 16,
  },
  fields: {
    gap: 4,
  },
  field: {
    flexDirection: 'row',
    alignItems: 'center',
    minHeight: 50,
    gap: 16,
  },
  label: {
    width: 78,
    color: '#7f8792',
    fontFamily: Platform.select({ ios: 'Menlo', android: 'monospace' }),
    fontSize: 11,
    letterSpacing: 1.3,
  },
  input: {
    flex: 1,
    color: '#eef1f5',
    fontFamily: Platform.select({ ios: 'Menlo', android: 'monospace' }),
    fontSize: 15,
    padding: 0,
  },
  switchRow: {
    minHeight: 58,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    borderTopWidth: 1,
    borderBottomWidth: 1,
    borderColor: '#242932',
  },
  switchCopy: {
    gap: 2,
  },
  switch: {
    alignSelf: 'center',
  },
  switchTitle: {
    color: '#e7eaf0',
    fontSize: 15,
    fontWeight: '600',
  },
  switchCaption: {
    color: '#737b87',
    fontSize: 12,
  },
  forgetButton: {
    alignSelf: 'flex-start',
    paddingVertical: 8,
  },
  forgetText: {
    color: '#ee9b91',
    fontSize: 14,
    fontWeight: '600',
  },
  connectButton: {
    minHeight: 52,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: 5,
    backgroundColor: '#81d4a3',
    marginTop: 6,
  },
  connectButtonDisabled: {
    opacity: 0.35,
  },
  connectButtonPressed: {
    opacity: 0.8,
  },
  connectText: {
    color: '#07120c',
    fontFamily: Platform.select({ ios: 'Menlo', android: 'monospace' }),
    fontSize: 13,
    fontWeight: '800',
    letterSpacing: 1.4,
  },
})
