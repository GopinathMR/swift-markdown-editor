import AppKit

/// The one text view. Its storage is the markdown source; everything rendered is attributes.
final class EditorTextView: NSTextView {
  weak var coordinator: EditorCoordinator?
  var maxContentWidth: CGFloat? = 860
  var onWidthChange: ((CGFloat) -> Void)?
  private var lastContainerWidth: CGFloat = 0

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    updateInsets()
  }

  func updateInsets() {
    let side = max(
      28, ((bounds.width - (maxContentWidth ?? .greatestFiniteMagnitude)) / 2).rounded())
    if textContainerInset.width != side { textContainerInset = NSSize(width: side, height: 28) }
    let w = textContainer?.size.width ?? 0
    if abs(w - lastContainerWidth) > 1 {
      lastContainerWidth = w
      onWidthChange?(w)
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    coordinator?.appearanceDidChange()
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if coordinator?.handleClick(at: point, command: event.modifierFlags.contains(.command)) == true
    {
      return
    }
    super.mouseDown(with: event)
  }

  override func keyDown(with event: NSEvent) {
    if coordinator?.handleKeyDown(event) == true { return }
    super.keyDown(with: event)
  }

  override func insertText(_ string: Any, replacementRange: NSRange) {
    if let s = string as? String,
      coordinator?.handleInsert(s, replacementRange: replacementRange) == true
    {
      return
    }
    super.insertText(string, replacementRange: replacementRange)
    if let s = string as? String, s.count == 1,
      s.first?.isLetter == true || s.first?.isNumber == true
    {
      coordinator?.maybeCompleteEmoji()
    }
  }

  override func insertNewline(_ sender: Any?) {
    if coordinator?.handleNewline(shift: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
      == true
    {
      return
    }
    super.insertNewline(sender)
  }

  override func insertTab(_ sender: Any?) {
    if coordinator?.handleTab(backward: false) == true { return }
    super.insertTab(sender)
  }

  override func insertBacktab(_ sender: Any?) {
    if coordinator?.handleTab(backward: true) == true { return }
    super.insertBacktab(sender)
  }

  override func deleteBackward(_ sender: Any?) {
    if coordinator?.handleDeleteBackward() == true { return }
    super.deleteBackward(sender)
  }

  override func paste(_ sender: Any?) {
    if coordinator?.handlePaste(plain: false) == true { return }
    super.paste(sender)
  }

  override func pasteAsPlainText(_ sender: Any?) {
    if coordinator?.handlePaste(plain: true) == true { return }
    super.pasteAsPlainText(sender)
  }

  override func copy(_ sender: Any?) {
    if coordinator?.handleCopy() == true { return }
    super.copy(sender)
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = super.menu(for: event) ?? NSMenu()
    coordinator?.decorateContextMenu(menu, at: convert(event.locationInWindow, from: nil))
    return menu
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    if coordinator?.handleDrop(sender) == true { return true }
    return super.performDragOperation(sender)
  }

  override func scrollWheel(with event: NSEvent) {
    super.scrollWheel(with: event)
    coordinator?.viewportDidScroll()
  }
}
