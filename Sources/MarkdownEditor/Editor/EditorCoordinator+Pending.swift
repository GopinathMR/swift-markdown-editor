import AppKit

// Hooks filled in by later layers (clipboard, view modes).
extension EditorCoordinator {
  func copyAsMarkdown() {}
  func copyAsHTML() {}
  func handlePaste(plain: Bool) -> Bool {
    !plain && mode == .rendered && pasteImagesIfPresent(.general)
  }
  func handleCopy() -> Bool { false }
  func selectionDidChangeHooks() { updateSubstitutionContext() }
  func focusModeChanged() {}
  func typewriterModeChanged() {}
  func focusAlpha(for fragment: NSTextLayoutFragment) -> CGFloat { 1 }
}
