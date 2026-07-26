import type {
  ConnectionState,
  ConnectionStateEvent,
  EllaTerminalView,
  HostKeyRequestEvent,
  TerminalErrorCode,
  TerminalKey,
} from 'ella-terminal'
import {
  createContext,
  type PropsWithChildren,
  useCallback,
  useContext,
  useRef,
  useState,
} from 'react'
import { Alert } from 'react-native'

import {
  deletePassword,
  deleteTrustedHostKey,
  getLastConnection,
  getPassword,
  getTrustedHostKey,
  normalizeHost,
  setLastConnection,
  setPassword,
  setTrustedHostKey,
  type ConnectionFields,
} from './storage'

export interface ConnectionForm extends ConnectionFields {
  password: string
  savePassword: boolean
}

interface ConnectionDefaults extends ConnectionForm {
  hasTrustedHostKey: boolean
}

interface ConnectionControllerValue {
  state: ConnectionState
  connectionHost: string | null
  controlModifierActive: boolean
  viewReady: boolean
  hybridRef: (ref: EllaTerminalView) => void
  onConnectionStateChange: (event: ConnectionStateEvent) => void
  onControlModifierChange: (active: boolean) => void
  onHostKeyRequest: (event: HostKeyRequestEvent) => void
  sendKey: (key: TerminalKey) => void
  toggleControlModifier: () => void
  showKeyboard: () => void
  hideKeyboard: () => void
  connect: (form: ConnectionForm) => Promise<void>
  disconnect: () => void
  getDefaults: () => Promise<ConnectionDefaults>
  hasTrustedHostKey: (fields: ConnectionFields) => Promise<boolean>
  forgetHostKey: (fields: ConnectionFields) => Promise<void>
}

const errorMessages: Record<TerminalErrorCode, string> = {
  connectionTimeout: 'Connection timed out.',
  connectionRefused: 'Connection was refused.',
  hostKeyRejected: 'Host key was rejected.',
  hostKeyTimeout: 'Host key confirmation timed out.',
  hostKeyMismatch: 'Host key does not match the trusted key.',
  authUnsupported: 'The server does not support password authentication.',
  authenticationFailed: 'Authentication failed.',
  ptyFailed: 'Remote terminal setup failed.',
  remoteClosed: 'Remote session closed.',
  cancelled: 'Connection cancelled.',
  internalError: 'SSH session failed.',
}

const ConnectionControllerContext = createContext<ConnectionControllerValue | null>(
  null,
)

function nextConnectionId() {
  return `connection-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`
}

export function ConnectionControllerProvider({ children }: PropsWithChildren) {
  const terminalRef = useRef<EllaTerminalView | null>(null)
  const connectionIdRef = useRef<string | null>(null)
  const hostKeyRequestRef = useRef<string | null>(null)
  const hostKeyWriteQueueRef = useRef<Promise<void>>(Promise.resolve())
  const [state, setState] = useState<ConnectionState>('idle')
  const [connectionHost, setConnectionHost] = useState<string | null>(null)
  const [controlModifierActive, setControlModifierActive] = useState(false)
  const [viewReady, setViewReady] = useState(false)

  const enqueueHostKeyOperation = useCallback(
    <T,>(operation: () => Promise<T>): Promise<T> => {
      const result = hostKeyWriteQueueRef.current.then(operation)
      hostKeyWriteQueueRef.current = result.then(
        () => {},
        () => {},
      )
      return result
    },
    [],
  )

  const hybridRef = useCallback((ref: EllaTerminalView) => {
    terminalRef.current = ref
    setViewReady(true)
  }, [])

  const onConnectionStateChange = useCallback((event: ConnectionStateEvent) => {
    if (event.connectionId !== connectionIdRef.current) return
    setState(event.state)

    if (event.state === 'error') {
      hostKeyRequestRef.current = null
      connectionIdRef.current = null
      setConnectionHost(null)
      terminalRef.current?.setControlModifier(false)
      const message = event.errorCode
        ? errorMessages[event.errorCode]
        : errorMessages.internalError
      Alert.alert('Connection failed', message)
    } else if (event.state === 'disconnected') {
      hostKeyRequestRef.current = null
      connectionIdRef.current = null
      setConnectionHost(null)
      terminalRef.current?.setControlModifier(false)
    }
  }, [])

  const onControlModifierChange = useCallback((active: boolean) => {
    setControlModifierActive(active)
  }, [])

  const sendKey = useCallback((key: TerminalKey) => {
    terminalRef.current?.sendKey(key)
  }, [])

  const toggleControlModifier = useCallback(() => {
    const active = !controlModifierActive
    setControlModifierActive(active)
    terminalRef.current?.setControlModifier(active)
  }, [controlModifierActive])

  const showKeyboard = useCallback(() => {
    terminalRef.current?.showKeyboard()
  }, [])

  const hideKeyboard = useCallback(() => {
    terminalRef.current?.hideKeyboard()
  }, [])

  const onHostKeyRequest = useCallback((event: HostKeyRequestEvent) => {
    if (
      event.connectionId !== connectionIdRef.current ||
      hostKeyRequestRef.current != null
    ) {
      return
    }
    hostKeyRequestRef.current = event.requestId

    const isCurrentRequest = () =>
      event.connectionId === connectionIdRef.current &&
      hostKeyRequestRef.current === event.requestId

    const respond = (accepted: boolean) => {
      if (!isCurrentRequest()) return
      hostKeyRequestRef.current = null
      terminalRef.current?.respondToHostKey(
        event.connectionId,
        event.requestId,
        accepted,
      )
    }

    Alert.alert(
      'Trust this host?',
      `${event.host}:${event.port}\n${event.algorithm}\n${event.fingerprint}`,
      [
        {
          text: 'Cancel',
          style: 'cancel',
          onPress: () => respond(false),
        },
        {
          text: 'Trust',
          onPress: () => {
            if (!isCurrentRequest()) return
            const fields = { host: event.host, port: event.port }
            const trustedHostKey = {
              algorithm: event.algorithm,
              fingerprint: event.fingerprint,
            }
            const operation = enqueueHostKeyOperation(async () => {
              if (!isCurrentRequest()) return
              await setTrustedHostKey(fields, trustedHostKey)
              if (isCurrentRequest()) {
                respond(true)
              } else {
                await deleteTrustedHostKey(fields)
              }
            })
            void operation.catch(() => {
              if (!isCurrentRequest()) return
              respond(false)
              Alert.alert('Connection failed', 'Could not save the trusted host key.')
            })
          },
        },
      ],
      { cancelable: false },
    )
  }, [enqueueHostKeyOperation])

  const connect = useCallback(async (form: ConnectionForm) => {
    const terminal = terminalRef.current
    if (terminal == null) throw new Error('Terminal is not ready.')

    const fields: ConnectionFields = {
      host: normalizeHost(form.host),
      port: form.port,
      username: form.username.trim(),
    }
    await setLastConnection(fields)
    if (form.savePassword) {
      await setPassword(fields, form.password)
    } else {
      await deletePassword(fields)
    }
    const trustedHostKey = await enqueueHostKeyOperation(() =>
      getTrustedHostKey(fields),
    )
    const connectionId = nextConnectionId()
    connectionIdRef.current = connectionId
    hostKeyRequestRef.current = null
    setConnectionHost(fields.host)
    setState('connecting')

    try {
      terminal.connect({
        connectionId,
        ...fields,
        password: form.password,
        trustedHostKey: trustedHostKey ?? undefined,
      })
    } catch {
      connectionIdRef.current = null
      setConnectionHost(null)
      setState('error')
      throw new Error(errorMessages.internalError)
    }
  }, [enqueueHostKeyOperation])

  const disconnect = useCallback(() => {
    const connectionId = connectionIdRef.current
    if (connectionId == null) return
    setState('disconnecting')
    terminalRef.current?.disconnect(connectionId)
  }, [])

  const getDefaults = useCallback(async (): Promise<ConnectionDefaults> => {
    const last = await getLastConnection()
    if (last == null) {
      return {
        host: '',
        port: 22,
        username: '',
        password: '',
        savePassword: false,
        hasTrustedHostKey: false,
      }
    }
    const [password, trustedHostKey] = await Promise.all([
      getPassword(last),
      enqueueHostKeyOperation(() => getTrustedHostKey(last)),
    ])
    return {
      ...last,
      password: password ?? '',
      savePassword: password != null,
      hasTrustedHostKey: trustedHostKey != null,
    }
  }, [enqueueHostKeyOperation])

  const hasTrustedHostKey = useCallback(async (fields: ConnectionFields) => {
    return (
      await enqueueHostKeyOperation(() => getTrustedHostKey(fields))
    ) != null
  }, [enqueueHostKeyOperation])

  const forgetHostKey = useCallback(async (fields: ConnectionFields) => {
    await enqueueHostKeyOperation(() => deleteTrustedHostKey(fields))
  }, [enqueueHostKeyOperation])

  return (
    <ConnectionControllerContext.Provider
      value={{
        state,
        connectionHost,
        controlModifierActive,
        viewReady,
        hybridRef,
        onConnectionStateChange,
        onControlModifierChange,
        onHostKeyRequest,
        sendKey,
        toggleControlModifier,
        showKeyboard,
        hideKeyboard,
        connect,
        disconnect,
        getDefaults,
        hasTrustedHostKey,
        forgetHostKey,
      }}
    >
      {children}
    </ConnectionControllerContext.Provider>
  )
}

export function useConnectionController() {
  const controller = useContext(ConnectionControllerContext)
  if (controller == null) {
    throw new Error('ConnectionControllerProvider is missing.')
  }
  return controller
}
