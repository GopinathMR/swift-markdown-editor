import AppKit
import SwiftUI

/// A Typora-style markdown editor: one pane, markdown rendered inline, the source revealed
/// wherever the caret is. `text` is the markdown and is never reformatted.
public struct MarkdownEditor: NSViewRepresentable {
  @Binding var text: String
  var documentURL: URL?
  var controller: MarkdownEditorController?
  var preferences: EditorPreferences
  var theme: EditorTheme
  var hooks: EditorHooks

  public init(
    text: Binding<String>,
    documentURL: URL? = nil,
    controller: MarkdownEditorController? = nil,
    preferences: EditorPreferences = .init(),
    theme: EditorTheme = .default,
    hooks: EditorHooks = .init()
  ) {
    _text = text
    self.documentURL = documentURL
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

  public func makeNSView(context: Context) -> NSScrollView {
    let c = context.coordinator.coordinator
    c.controller = controller
    controller?.coordinator = c
    c.load(text)
    c.onTextChange = { [binding = $text] s in
      if binding.wrappedValue != s { binding.wrappedValue = s }
    }
    controller?.documentDidChange(c.model, text: text)
    return c.scrollView
  }

  public func updateNSView(_ view: NSScrollView, context: Context) {
    let c = context.coordinator.coordinator
    c.hooks = hooks
    if c.documentURL != documentURL { c.documentURL = documentURL }
    if c.controller !== controller {
      c.controller = controller
      controller?.coordinator = c
    }
    c.setPreferences(preferences)
    c.setTheme(theme)
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
