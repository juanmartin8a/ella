import { StatusBar } from 'expo-status-bar';
import { StyleSheet, View } from 'react-native';
import { EllaTerminal } from 'ella-terminal';

export default function App() {
  return (
    <View style={styles.container}>
      <EllaTerminal style={styles.terminal} />
      <StatusBar hidden />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#000',
  },
  terminal: {
    flex: 1,
    width: '100%',
    height: '100%',
  },
});
