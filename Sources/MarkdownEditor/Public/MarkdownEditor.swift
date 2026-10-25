import AppKit
import SwiftUI

/// A Typora-style markdown editor: one pane, markdown rendered inline, the source revealed
/// wherever the caret is.
///
/// Two modes:
/// - `init(text:)` edits a string the host owns; the editor never touches files.
/// - `init(fileURL:)` reads, watches and saves the file itself (see `MarkdownEditorController`
///   `save()`, `isDirty`, `watchFile`).
public struct MarkdownEditor: NSViewRepresentable {
  @Binding var text: String
  var documentURL: URL?
  var fileURL: URL?
  var watchFile: Bool
  var outlinePosition: OutlinePosition
  var controller: MarkdownEditorController?
  var preferences: EditorPreferences
  var theme: EditorTheme
  var hooks: EditorHooks

  /// String mode. `text` is the markdown and is never reformatted.
  public init(
    text: Binding<String>,
    documentURL: URL? = nil,
    controller: MarkdownEditorController? = nil,
    preferences: EditorPreferences = .init(),
    theme: EditorTheme = .default,
    hooks: EditorHooks = .init(),
    outlinePosition: OutlinePosition = .right
  ) {
    _text = text
    self.documentURL = documentURL
    self.fileURL = nil
    self.watchFile = false
    self.outlinePosition = outlinePosition
    self.controller = controller
    self.preferences = preferences
    self.theme = theme
    self.hooks = hooks
  }

  /// File mode: the editor reads, watches (`watchFile`) and saves `fileURL` itself.
  public init(
    fileURL: URL,
    controller: MarkdownEditorController? = nil,
    preferences: EditorPreferences = .init(),
    theme: EditorTheme = .default,
    hooks: EditorHooks = .init(),
    watchFile: Bool = true,
    outlinePosition: OutlinePosition = .right
  ) {
    _text = .constant("")
    self.documentURL = fileURL
    self.fileURL = fileURL
    self.watchFile = watchFile
    self.outlinePosition = outlinePosition
    self.controller = controller
    self.preferences = preferences
    self.theme = theme
    self.hooks = hooks
  }

  public func makeCoordinator() -> EditorCoordinatorBox {
    EditorCoordinatorBox(
      EditorCoordinator(
        preferences: preferences, theme: theme, hooks: hooks, documentURL: documentURL))
  }

  public func makeNSView(context: Context) -> NSView {
    let c = context.coordinator.coordinator
    c.controller = controller
    let ctl = c.activeController
    ctl.coordinator = c
    if let fileURL {
      c.openedURL = fileURL
      ctl.watchFile = watchFile
      c.open(fileURL, watch: watchFile)
    } else {
      c.load(text)
      c.onTextChange = { [binding = $text] s in
        if binding.wrappedValue != s { binding.wrappedValue = s }
      }
    }
    ctl.outlinePosition = outlinePosition
    c.setOutline(outlinePosition)
    c.applied = (watchFile, outlinePosition)
    ctl.documentDidChange(c.model, text: c.storage.string)
    return c.container
  }

  public func updateNSView(_ view: NSView, context: Context) {
    let c = context.coordinator.coordinator
    c.hooks = hooks
    if c.controller !== controller {
      c.controller = controller
      c.activeController.coordinator = c
    }
    let ctl = c.activeController
    c.setPreferences(preferences)
    c.setTheme(theme)
    // Push init values only when the host changed them, so live controller changes stick.
    if c.applied.watch != watchFile { ctl.watchFile = watchFile }
    if c.applied.outline != outlinePosition { ctl.outlinePosition = outlinePosition }
    c.applied = (watchFile, outlinePosition)
    if let fileURL {
      if c.openedURL != fileURL {
        c.openedURL = fileURL
        c.file?.watching = false
        c.open(fileURL, watch: ctl.watchFile)
      }
      return
    }
    if c.documentURL != documentURL { c.documentURL = documentURL }
    c.onTextChange = { [binding = $text] s in
      if binding.wrappedValue != s { binding.wrappedValue = s }
    }
    if c.storage.string != text { c.setExternalText(text) }
  }
}

/// Opaque holder so the internal coordinator type stays internal.
@MainActor
public final class EditorCoordinatorBox {
  let coordinator: EditorCoordinator
  init(_ c: EditorCoordinator) { coordinator = c }
}
