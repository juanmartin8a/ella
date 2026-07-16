import * as SecureStore from 'expo-secure-store'

import type { TrustedHostKey } from 'ella-terminal'

export interface ConnectionFields {
  host: string
  port: number
  username: string
}

interface StoredConnection extends ConnectionFields {
  version: 1
}

interface StoredHostKey extends TrustedHostKey {
  version: 1
}

const LAST_CONNECTION_KEY = 'ella.last_connection.v1'
const PASSWORD_PREFIX = 'ella.password.'
const HOST_KEY_PREFIX = 'ella.host_key.'
const secureOptions: SecureStore.SecureStoreOptions = {
  keychainAccessible: SecureStore.WHEN_UNLOCKED_THIS_DEVICE_ONLY,
}

export function normalizeHost(value: string) {
  const trimmed = value.trim()
  const unwrapped =
    trimmed.startsWith('[') && trimmed.endsWith(']')
      ? trimmed.slice(1, -1)
      : trimmed
  return unwrapped.toLowerCase()
}

function encodeIdentifier(value: string) {
  return Array.from(new TextEncoder().encode(value), (byte) =>
    byte.toString(16).padStart(2, '0'),
  ).join('')
}

function passwordKey(fields: ConnectionFields) {
  const identity = `${normalizeHost(fields.host)}:${fields.port}:${fields.username}`
  return `${PASSWORD_PREFIX}${encodeIdentifier(identity)}`
}

function hostKey(fields: Pick<ConnectionFields, 'host' | 'port'>) {
  const identity = `${normalizeHost(fields.host)}:${fields.port}`
  return `${HOST_KEY_PREFIX}${encodeIdentifier(identity)}`
}

export async function getLastConnection(): Promise<ConnectionFields | null> {
  const value = await SecureStore.getItemAsync(LAST_CONNECTION_KEY, secureOptions)
  if (value == null) return null

  try {
    const record = JSON.parse(value) as Partial<StoredConnection>
    if (
      record.version !== 1 ||
      typeof record.host !== 'string' ||
      typeof record.username !== 'string' ||
      typeof record.port !== 'number' ||
      !Number.isInteger(record.port) ||
      record.port < 1 ||
      record.port > 65535
    ) {
      return null
    }
    return { host: record.host, port: record.port, username: record.username }
  } catch {
    return null
  }
}

export async function setLastConnection(fields: ConnectionFields) {
  const record: StoredConnection = { version: 1, ...fields }
  await SecureStore.setItemAsync(
    LAST_CONNECTION_KEY,
    JSON.stringify(record),
    secureOptions,
  )
}

export async function getPassword(fields: ConnectionFields) {
  return SecureStore.getItemAsync(passwordKey(fields), secureOptions)
}

export async function setPassword(fields: ConnectionFields, password: string) {
  await SecureStore.setItemAsync(passwordKey(fields), password, secureOptions)
}

export async function deletePassword(fields: ConnectionFields) {
  await SecureStore.deleteItemAsync(passwordKey(fields), secureOptions)
}

export async function getTrustedHostKey(
  fields: Pick<ConnectionFields, 'host' | 'port'>,
): Promise<TrustedHostKey | null> {
  const value = await SecureStore.getItemAsync(hostKey(fields), secureOptions)
  if (value == null) return null

  try {
    const record = JSON.parse(value) as Partial<StoredHostKey>
    if (
      record.version !== 1 ||
      typeof record.algorithm !== 'string' ||
      typeof record.fingerprint !== 'string' ||
      !record.fingerprint.startsWith('SHA256:')
    ) {
      return null
    }
    return { algorithm: record.algorithm, fingerprint: record.fingerprint }
  } catch {
    return null
  }
}

export async function setTrustedHostKey(
  fields: Pick<ConnectionFields, 'host' | 'port'>,
  trustedHostKey: TrustedHostKey,
) {
  const record: StoredHostKey = { version: 1, ...trustedHostKey }
  await SecureStore.setItemAsync(
    hostKey(fields),
    JSON.stringify(record),
    secureOptions,
  )
}

export async function deleteTrustedHostKey(
  fields: Pick<ConnectionFields, 'host' | 'port'>,
) {
  await SecureStore.deleteItemAsync(hostKey(fields), secureOptions)
}
