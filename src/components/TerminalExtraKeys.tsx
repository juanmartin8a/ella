import type { TerminalKey } from 'ella-terminal'
import { Platform, Pressable, StyleSheet, Text, View } from 'react-native'
import { useKeyboardState } from 'react-native-keyboard-controller'

interface TerminalExtraKeysProps {
  controlModifierActive: boolean
  disabled: boolean
  onHideKeyboard: () => void
  onSendKey: (key: TerminalKey) => void
  onShowKeyboard: () => void
  onToggleControlModifier: () => void
}

interface KeycapProps {
  accessibilityLabel: string
  active?: boolean
  disabled?: boolean
  label: string
  onPress: () => void
  small?: boolean
}

function Keycap({
  accessibilityLabel,
  active = false,
  disabled = false,
  label,
  onPress,
  small = false,
}: KeycapProps) {
  return (
    <Pressable
      accessibilityLabel={accessibilityLabel}
      accessibilityRole="button"
      accessibilityState={{ disabled, selected: active }}
      disabled={disabled}
      onPress={onPress}
      style={({ pressed }) => [
        styles.keycap,
        small && styles.smallKeycap,
        active && styles.activeKeycap,
        disabled && styles.disabledKeycap,
        pressed && styles.pressedKeycap,
      ]}
    >
      <Text style={[styles.keyLabel, small && styles.smallKeyLabel, active && styles.activeKeyLabel]}>
        {label}
      </Text>
    </Pressable>
  )
}

export function TerminalExtraKeys({
  controlModifierActive,
  disabled,
  onHideKeyboard,
  onSendKey,
  onShowKeyboard,
  onToggleControlModifier,
}: TerminalExtraKeysProps) {
  const keyboardVisible = useKeyboardState((state) => state.isVisible)

  return (
    <View style={styles.toolbar}>
      <View style={styles.keyRow}>
        <View style={styles.keySlot}>
          <Keycap
            accessibilityLabel="Escape"
            disabled={disabled}
            label="esc"
            onPress={() => onSendKey('escape')}
          />
        </View>
        <View style={styles.keySlot}>
          <Keycap
            accessibilityLabel="Tab"
            disabled={disabled}
            label="tab"
            onPress={() => onSendKey('tab')}
          />
        </View>
        <View style={styles.wideKeySlot}>
          <Keycap
            accessibilityLabel={controlModifierActive ? 'Control, active' : 'Control'}
            active={controlModifierActive}
            disabled={disabled}
            label="ctrl"
            onPress={onToggleControlModifier}
          />
        </View>
        <View style={styles.keySlot}>
          <Keycap
            accessibilityLabel="Left arrow"
            disabled={disabled}
            label="←"
            onPress={() => onSendKey('left')}
          />
        </View>
        <View style={[styles.keySlot, styles.verticalArrows]}>
          <Keycap
            accessibilityLabel="Up arrow"
            disabled={disabled}
            label="↑"
            onPress={() => onSendKey('up')}
            small
          />
          <Keycap
            accessibilityLabel="Down arrow"
            disabled={disabled}
            label="↓"
            onPress={() => onSendKey('down')}
            small
          />
        </View>
        <View style={styles.keySlot}>
          <Keycap
            accessibilityLabel="Right arrow"
            disabled={disabled}
            label="→"
            onPress={() => onSendKey('right')}
          />
        </View>
        <View style={[styles.keySlot, styles.keyboardSlot]}>
          <Keycap
            accessibilityLabel={keyboardVisible ? 'Hide keyboard' : 'Show keyboard'}
            label={keyboardVisible ? 'hide' : 'kbd'}
            onPress={keyboardVisible ? onHideKeyboard : onShowKeyboard}
          />
        </View>
      </View>
    </View>
  )
}

const styles = StyleSheet.create({
  toolbar: {
    backgroundColor: 'transparent',
    paddingTop: 4,
    paddingBottom: 4,
    paddingHorizontal: 6,
  },
  keyRow: {
    flexDirection: 'row',
    gap: 5,
    height: Platform.select({ android: 48, default: 44 }),
  },
  keySlot: {
    flex: 1,
  },
  wideKeySlot: {
    flex: 1.15,
  },
  keyboardSlot: {
    marginLeft: 3,
  },
  verticalArrows: {
    gap: 2,
  },
  keycap: {
    flex: 1,
    minWidth: 0,
    alignItems: 'center',
    justifyContent: 'center',
    borderWidth: 1,
    borderBottomWidth: 2,
    borderColor: '#656B73',
    borderBottomColor: '#3A3E44',
    borderRadius: 6,
    backgroundColor: 'transparent',
  },
  smallKeycap: {
    borderRadius: 4,
  },
  activeKeycap: {
    borderColor: '#B4DFFF',
    borderBottomColor: '#70B7EB',
    backgroundColor: 'rgba(112, 183, 235, 0.14)',
  },
  disabledKeycap: {
    opacity: 0.38,
  },
  pressedKeycap: {
    borderBottomWidth: 1,
    backgroundColor: 'rgba(255, 255, 255, 0.12)',
    transform: [{ translateY: 1 }],
  },
  keyLabel: {
    color: '#E4E7EB',
    fontFamily: Platform.select({ ios: 'Menlo', default: 'monospace' }),
    fontSize: 12,
    fontWeight: '500',
  },
  smallKeyLabel: {
    fontSize: 12,
    lineHeight: 12,
  },
  activeKeyLabel: {
    color: '#D7F0FF',
  },
})
