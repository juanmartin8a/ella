import NitroModules
import SwiftTerm
import UIKit

final class HybridEllaTerminalView: HybridEllaTerminalViewSpec, TerminalViewDelegate {
  private let terminalView = EllaSwiftTermView(frame: .zero)
  private var currentLine = ""

  var view: UIView { terminalView }

  override init() {
    super.init()

    terminalView.terminalDelegate = self
    terminalView.nativeBackgroundColor = .black
    terminalView.nativeForegroundColor = .white
    terminalView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)

    terminalView.onFirstLayout = { [weak terminalView] in
      terminalView?.feed(text: "Ella terminal\r\nSSH offline.\r\n$ ")
      _ = terminalView?.becomeFirstResponder()
    }
  }

  deinit {
    terminalView.updateUiClosed()
  }

  func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
  func setTerminalTitle(source: TerminalView, title: String) {}
  func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

  func send(source: TerminalView, data: ArraySlice<UInt8>) {
    let text = String(decoding: data, as: UTF8.self)

    if text == "\r" || text == "\n" {
      terminalView.feed(text: "\r\nSSH offline.\r\n$ ")
      currentLine = ""
      return
    }

    if text == "\u{7f}" || text == "\u{8}" {
      if !currentLine.isEmpty {
        currentLine.removeLast()
        terminalView.feed(text: "\u{8} \u{8}")
      }
      return
    }

    currentLine += text
    terminalView.feed(byteArray: data)
  }

  func scrolled(source: TerminalView, position: Double) {}

  func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
    guard let url = URL(string: link) else { return }
    UIApplication.shared.open(url)
  }

  func bell(source: TerminalView) {}

  func clipboardCopy(source: TerminalView, content: Data) {
    UIPasteboard.general.string = String(data: content, encoding: .utf8)
  }

  func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
  func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

private final class EllaSwiftTermView: TerminalView {
  var onFirstLayout: (() -> Void)?

  override func layoutSubviews() {
    super.layoutSubviews()
    guard !bounds.isEmpty, let onFirstLayout else { return }
    self.onFirstLayout = nil
    onFirstLayout()
  }
}
