import AppKit

// Hooks filled in by later layers (clipboard, images, tables, find, view modes).
extension EditorCoordinator {
  func insertImageCommand() { insert("![]()", caretOffset: 4) }
  func deleteTableRowAtCaret() {}
  func copyAsMarkdown() {}
  func copyAsHTML() {}
  func handlePaste(plain: Bool) -> Bool { false }
  func handleCopy() -> Bool { false }
  func handleDrop(_ info: NSDraggingInfo) -> Bool { false }
  func viewportDidScroll() {}
  func overlaysNeedUpdate() {}
  func selectionDidChangeHooks() { updateSubstitutionContext() }
  func focusModeChanged() {}
  func typewriterModeChanged() {}
}

extension EditorCoordinator {
  func focusAlpha(for fragment: NSTextLayoutFragment) -> CGFloat { 1 }
}

extension EditorCoordinator {
  func decorateImageMenu(_ menu: NSMenu, index: Int) {}
  func decorateTableMenu(_ menu: NSMenu, index: Int) {}
}
