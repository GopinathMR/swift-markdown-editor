import AppKit
import SwiftUI

/// Typora's Paragraph, Format, Edit and View commands.
public enum EditorCommand: Hashable, Sendable {
  case heading(Int)
  case paragraph, increaseHeading, decreaseHeading
  case table, codeFence, mathBlock, quote, orderedList, unorderedList, taskList
  case indent, outdent, horizontalRule, footnote, toc, frontMatter
  case strong, emphasis, underline, inlineCode, strikethrough, highlight, inlineMath
  case link, image, clearFormat
  case selectLine, selectStyleScope, selectWord, deleteWord, deleteTableRow
  case jumpTop, jumpBottom, jumpSelection
  case copyAsMarkdown, copyAsHTML, pasteAsPlainText
  case toggleSourceMode, toggleFocusMode, toggleTypewriterMode
  case zoomIn, zoomOut, zoomReset, find, findAndReplace
  case save

  public static let all: [EditorCommand] =
    (1...6).map(EditorCommand.heading) + [
      .paragraph, .increaseHeading, .decreaseHeading, .table, .codeFence, .mathBlock, .quote,
      .orderedList, .unorderedList, .taskList, .indent, .outdent, .horizontalRule, .footnote, .toc,
      .frontMatter, .strong, .emphasis, .underline, .inlineCode, .strikethrough, .highlight,
      .inlineMath, .link, .image, .clearFormat, .selectLine, .selectStyleScope, .selectWord,
      .deleteWord, .deleteTableRow, .jumpTop, .jumpBottom, .jumpSelection, .copyAsMarkdown,
      .copyAsHTML, .pasteAsPlainText, .toggleSourceMode, .toggleFocusMode, .toggleTypewriterMode,
      .zoomIn, .zoomOut, .zoomReset, .find, .findAndReplace, .save,
    ]

  public var title: String {
    switch self {
    case .heading(let n): return "Heading \(n)"
    case .paragraph: return "Paragraph"
    case .increaseHeading: return "Increase Heading Level"
    case .decreaseHeading: return "Decrease Heading Level"
    case .table: return "Table"
    case .codeFence: return "Code Fences"
    case .mathBlock: return "Math Block"
    case .quote: return "Quote"
    case .orderedList: return "Ordered List"
    case .unorderedList: return "Unordered List"
    case .taskList: return "Task List"
    case .indent: return "Indent"
    case .outdent: return "Outdent"
    case .horizontalRule: return "Horizontal Line"
    case .footnote: return "Footnotes"
    case .toc: return "Table of Contents"
    case .frontMatter: return "YAML Front Matter"
    case .strong: return "Strong"
    case .emphasis: return "Emphasis"
    case .underline: return "Underline"
    case .inlineCode: return "Code"
    case .strikethrough: return "Strike"
    case .highlight: return "Highlight"
    case .inlineMath: return "Inline Math"
    case .link: return "Hyperlink"
    case .image: return "Image"
    case .clearFormat: return "Clear Format"
    case .selectLine: return "Select Line/Sentence"
    case .selectStyleScope: return "Select Style Scope"
    case .selectWord: return "Select Word"
    case .deleteWord: return "Delete Word"
    case .deleteTableRow: return "Delete Row"
    case .jumpTop: return "Jump to Top"
    case .jumpBottom: return "Jump to Bottom"
    case .jumpSelection: return "Jump to Selection"
    case .copyAsMarkdown: return "Copy as Markdown"
    case .copyAsHTML: return "Copy as HTML Code"
    case .pasteAsPlainText: return "Paste as Plain Text"
    case .toggleSourceMode: return "Source Code Mode"
    case .toggleFocusMode: return "Focus Mode"
    case .toggleTypewriterMode: return "Typewriter Mode"
    case .zoomIn: return "Zoom In"
    case .zoomOut: return "Zoom Out"
    case .zoomReset: return "Actual Size"
    case .find: return "Find…"
    case .findAndReplace: return "Find and Replace…"
    case .save: return "Save"
    }
  }

  /// Typora's macOS defaults.
  public var defaultShortcut: KeyboardShortcut? {
    func k(_ c: Character, _ m: EventModifiers = .command) -> KeyboardShortcut {
      KeyboardShortcut(KeyEquivalent(c), modifiers: m)
    }
    func fn(_ code: Int) -> KeyboardShortcut {
      KeyboardShortcut(KeyEquivalent(Character(UnicodeScalar(UInt16(code))!)), modifiers: [])
    }
    switch self {
    case .heading(let n): return k(Character("\(n)"))
    case .paragraph: return k("0")
    case .increaseHeading: return k("=")
    case .decreaseHeading: return k("-")
    case .table: return k("t", [.command, .option])
    case .codeFence: return k("c", [.command, .option])
    case .mathBlock: return k("b", [.command, .option])
    case .quote: return k("q", [.command, .option])
    case .orderedList: return k("o", [.command, .option])
    case .unorderedList: return k("u", [.command, .option])
    case .taskList: return k("x", [.command, .option])
    case .indent: return k("]")
    case .outdent: return k("[")
    case .horizontalRule: return k("-", [.command, .option])
    case .footnote: return k("r", [.command, .option])
    case .toc, .frontMatter, .copyAsHTML: return nil
    case .strong: return k("b")
    case .emphasis: return k("i")
    case .underline: return k("u")
    case .inlineCode: return k("`", [.command, .shift])
    case .strikethrough: return k("`", [.control, .shift])
    case .highlight: return k("h", [.command, .shift])
    case .inlineMath: return k("m", [.control])
    case .link: return k("k")
    case .image: return k("i", [.command, .control])
    case .clearFormat: return k("\\")
    case .selectLine: return k("l")
    case .selectStyleScope: return k("e")
    case .selectWord: return k("d")
    case .deleteWord: return k("d", [.command, .shift])
    case .deleteTableRow: return KeyboardShortcut(.delete, modifiers: [.command, .shift])
    case .jumpTop: return KeyboardShortcut(.upArrow, modifiers: .command)
    case .jumpBottom: return KeyboardShortcut(.downArrow, modifiers: .command)
    case .jumpSelection: return k("j")
    case .copyAsMarkdown: return k("c", [.command, .shift])
    case .pasteAsPlainText: return k("v", [.command, .shift])
    case .toggleSourceMode: return k("/")
    case .toggleFocusMode: return fn(NSF8FunctionKey)
    case .toggleTypewriterMode: return fn(NSF9FunctionKey)
    case .zoomIn: return k("=", [.command, .shift])
    case .zoomOut: return k("-", [.command, .shift])
    case .zoomReset: return k("0", [.command, .shift])
    case .find: return k("f")
    case .findAndReplace: return k("h", [.command, .option])
    case .save: return k("s")
    }
  }
}

extension FocusedValues {
  /// Set with `.focusedSceneValue(\.markdownEditorController, controller)` so
  /// `MarkdownEditorCommands` can reach the focused editor.
  @Entry public var markdownEditorController: MarkdownEditorController?
}

/// Paragraph, Format and View menus with Typora's shortcuts. Add to a scene's `.commands`.
public struct MarkdownEditorCommands: Commands {
  @FocusedValue(\.markdownEditorController) private var controller

  public init() {}

  private func item(_ c: EditorCommand) -> some View {
    Button(c.title) { controller?.perform(c) }
      .keyboardShortcut(c.defaultShortcut)
      .disabled(controller.map { !$0.canPerform(c) } ?? true)
  }

  public var body: some Commands {
    CommandGroup(replacing: .saveItem) { item(.save) }
    CommandGroup(after: .pasteboard) {
      item(.copyAsMarkdown)
      item(.copyAsHTML)
      Divider()
      item(.selectLine)
      item(.selectStyleScope)
      item(.selectWord)
      item(.deleteWord)
      Divider()
      item(.jumpTop)
      item(.jumpSelection)
      item(.jumpBottom)
    }
    CommandGroup(after: .textEditing) {
      item(.find)
      item(.findAndReplace)
    }
    CommandMenu("Paragraph") {
      ForEach(1...6, id: \.self) { item(.heading($0)) }
      item(.paragraph)
      Divider()
      item(.increaseHeading)
      item(.decreaseHeading)
      Divider()
      item(.table)
      item(.deleteTableRow)
      item(.codeFence)
      item(.mathBlock)
      Divider()
      item(.quote)
      item(.orderedList)
      item(.unorderedList)
      item(.taskList)
      item(.indent)
      item(.outdent)
      Divider()
      item(.horizontalRule)
      item(.footnote)
      item(.toc)
      item(.frontMatter)
    }
    CommandMenu("Format") {
      item(.strong)
      item(.emphasis)
      item(.underline)
      item(.inlineCode)
      item(.strikethrough)
      item(.highlight)
      item(.inlineMath)
      Divider()
      item(.link)
      item(.image)
      Divider()
      item(.clearFormat)
    }
    CommandGroup(after: .toolbar) {
      item(.toggleSourceMode)
      item(.toggleFocusMode)
      item(.toggleTypewriterMode)
      Divider()
      item(.zoomIn)
      item(.zoomOut)
      item(.zoomReset)
    }
  }
}
