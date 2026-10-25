import AppKit
import SwiftUI

extension EditorCoordinator {
  /// A click on a code block's language label opens the picker.
  func handleCodeLabelClick(at point: CGPoint) -> Bool {
    guard let inset = textView.textContainer?.size.width else { return false }
    for (content, fence) in styler.codeLabels {
      let line = rectInView(for: NSRange(location: content.location, length: 0))
      let right = textView.textContainerOrigin.x + inset - 5
      let hit = CGRect(x: right - 110, y: line.minY - 4, width: 110, height: line.height + 6)
      if hit.contains(point) {
        showLanguagePicker(
          fence: fence, at: CGRect(x: right - 60, y: line.minY, width: 60, height: line.height))
        return true
      }
    }
    return false
  }

  private func showLanguagePicker(fence: NSRange, at rect: CGRect) {
    let popover = NSPopover()
    popover.behavior = .transient
    let current = currentLanguage(fence)
    popover.contentViewController = NSHostingController(
      rootView: LanguagePicker(current: current) { [weak self, weak popover] name in
        popover?.close()
        self?.setLanguage(name, fence: fence)
      })
    popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
  }

  private func currentLanguage(_ fence: NSRange) -> String {
    let line = text.substring(with: fence).trimmingCharacters(in: .whitespaces)
    return String(line.drop { $0 == "`" || $0 == "~" }).trimmingCharacters(in: .whitespaces)
  }

  /// Rewrite the opening fence's info string, keeping the fence characters.
  func setLanguage(_ name: String, fence: NSRange) {
    let line = text.substring(with: fence) as NSString
    var i = 0
    while i < line.length, [0x20, 0x60, 0x7E].contains(line.character(at: i)) { i += 1 }
    let info = NSRange(location: fence.location + i, length: fence.length - i)
    let sel = textView.selectedRange()
    replace(info, with: name, selectAfter: sel.location >= info.end ? nil : sel)
  }

  func decorateContextMenu(_ menu: NSMenu, at point: CGPoint) {
    let idx = textView.characterIndexForInsertion(at: point)
    guard let (block, off) = model.innermostBlock(at: min(idx, max(0, text.length - 1))) else {
      return
    }
    if case .code = block.kind, let content = block.content?.shifted(by: off) {
      let item = NSMenuItem(
        title: "Copy Code", action: #selector(menuCopyCode(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = text.substring(with: content)
      menu.insertItem(item, at: 0)
      menu.insertItem(.separator(), at: 1)
    }
    decorateImageMenu(menu, index: idx)
    decorateTableMenu(menu, index: idx)
  }

  @objc func menuCopyCode(_ sender: NSMenuItem) {
    guard let code = sender.representedObject as? String else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(
      code.hasSuffix("\n") ? String(code.dropLast()) : code, forType: .string)
  }
}

struct LanguagePicker: View {
  let current: String
  let onPick: (String) -> Void
  @State private var query = ""

  var body: some View {
    let names = CodeHighlighter.languageNames + ["mermaid", "flow", "sequence"]
    let shown = query.isEmpty ? names : names.filter { $0.localizedCaseInsensitiveContains(query) }
    VStack(spacing: 6) {
      TextField("Language", text: $query)
        .textFieldStyle(.roundedBorder)
        .onSubmit { onPick(shown.first ?? query) }
      List(shown, id: \.self) { name in
        Button(name) { onPick(name) }
          .buttonStyle(.plain)
          .fontWeight(name == current ? .semibold : .regular)
      }
      .listStyle(.plain)
    }
    .padding(8)
    .frame(width: 200, height: 260)
  }
}
