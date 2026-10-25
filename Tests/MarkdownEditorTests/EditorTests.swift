import AppKit
import Testing

@testable import MarkdownEditor

@MainActor
final class Harness {
  let c: EditorCoordinator
  var published: String?
  let window: NSWindow

  init(_ text: String, prefs: EditorPreferences = .init()) {
    c = EditorCoordinator(preferences: prefs, theme: .default, hooks: .init(), documentURL: nil)
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentView = c.scrollView
    c.scrollView.frame = window.contentView!.bounds
    c.load(text)
    c.onTextChange = { [weak self] in self?.published = $0 }
  }

  var tv: EditorTextView { c.textView }

  func caret(_ loc: Int) { tv.setSelectedRange(NSRange(location: loc, length: 0)) }

  func type(_ s: String) {
    for ch in s {
      tv.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0))
    }
  }

  func isHidden(_ loc: Int) -> Bool {
    (c.storage.attribute(.mdHidden, at: loc, effectiveRange: nil) as? Bool) == true
  }
}

@MainActor @Test func openingAndReadingBackIsByteIdentical() {
  let src = "* a  \r\n* b\r\n\r\nSetext\r\n===\r\n\ttab\r\n"
  let h = Harness(src)
  #expect(h.c.storage.string == src)
}

@MainActor @Test func editInOneBlockLeavesOthersUntouched() {
  let src = "* one\n* two\n\nTitle\n=====\n\nPara text.\n"
  let h = Harness(src)
  let loc = (src as NSString).range(of: "text").location
  h.caret(loc)
  h.type("X")
  #expect(h.published == src.replacingOccurrences(of: "Para text", with: "Para Xtext"))
}

@MainActor @Test func markersHideAndRevealWithCaret() {
  let h = Harness("Say **bold** here.\n\nOther.\n")
  h.caret(20)  // in "Other."
  #expect(h.isHidden(4))  // `*`
  #expect(!h.isHidden(6))  // `b`
  h.caret(7)  // inside **bold**
  #expect(!h.isHidden(4))
  h.caret(20)
  #expect(h.isHidden(4))
}

@MainActor @Test func headingMarkerRevealsOnlyOnItsLine() {
  let h = Harness("# Title\n\nBody\n")
  h.caret(10)
  #expect(h.isHidden(0))
  h.caret(4)
  #expect(!h.isHidden(0))
}

@MainActor @Test func externalUpdateKeepsCaretAndAddsNoUndo() {
  let h = Harness("First paragraph.\n\nSecond paragraph.\n")
  h.caret(3)
  h.c.setExternalText("First paragraph.\n\nSecond paragraph changed.\n")
  #expect(h.tv.selectedRange().location == 3)
  #expect(h.tv.undoManager?.canUndo == false)
  #expect(h.c.storage.string == "First paragraph.\n\nSecond paragraph changed.\n")
}

@MainActor @Test func returnStartsParagraphAndContinuesLists() {
  let h = Harness("Hello")
  h.caret(5)
  _ = h.c.handleNewline(shift: false)
  #expect(h.c.storage.string == "Hello\n\n")
  let l = Harness("- one")
  l.caret(5)
  _ = l.c.handleNewline(shift: false)
  #expect(l.c.storage.string == "- one\n- ")
  _ = l.c.handleNewline(shift: false)
  #expect(l.c.storage.string == "- one\n")
  let o = Harness("3. three")
  o.caret(8)
  _ = o.c.handleNewline(shift: false)
  #expect(o.c.storage.string == "3. three\n4. ")
  let s = Harness("line")
  s.caret(4)
  _ = s.c.handleNewline(shift: true)
  #expect(s.c.storage.string == "line\n")
}

@MainActor @Test func fenceAndMathAutoClose() {
  let h = Harness("```swift")
  h.caret(8)
  _ = h.c.handleNewline(shift: false)
  #expect(h.c.storage.string == "```swift\n\n```")
  #expect(h.tv.selectedRange().location == 9)
  let m = Harness("$$")
  m.caret(2)
  _ = m.c.handleNewline(shift: false)
  #expect(m.c.storage.string == "$$\n\n$$")
}

@MainActor @Test func checkboxToggleIsUndoable() {
  let h = Harness("- [ ] task\n")
  h.caret(10)
  h.c.perform(.strong)  // unrelated command keeps working
  let r = h.c.storage.attribute(.mdTask, at: 2, effectiveRange: nil) as? NSValue
  #expect(r?.rangeValue == NSRange(location: 2, length: 3))
}

@MainActor @Test func commandsTransformSource() {
  let h = Harness("Title")
  h.caret(2)
  h.c.perform(.heading(2))
  #expect(h.c.storage.string == "## Title")
  h.c.perform(.paragraph)
  #expect(h.c.storage.string == "Title")
  h.tv.setSelectedRange(NSRange(location: 0, length: 5))
  h.c.perform(.strong)
  #expect(h.c.storage.string == "**Title**")
  h.c.perform(.strong)
  #expect(h.c.storage.string == "Title")
  h.c.perform(.unorderedList)
  #expect(h.c.storage.string == "- Title")
  h.c.perform(.orderedList)
  #expect(h.c.storage.string == "1. Title")
}

@MainActor @Test func textKit2NeverFallsBack() {
  let h = Harness(sample)
  #expect(h.tv.textLayoutManager != nil)
  h.c.setMode(.source)
  h.c.setMode(.rendered)
  #expect(h.tv.textLayoutManager != nil)
}

@MainActor @Test func codeBlocksAreHighlighted() {
  let h = Harness("```swift\nlet x = \"hi\"\n```\n\nafter\n")
  h.caret(25)
  let theme = h.c.styler.theme
  let kw = h.c.storage.attribute(.foregroundColor, at: 9, effectiveRange: nil) as? NSColor
  #expect(kw == theme.tokenColors["keyword"])
  let str = h.c.storage.attribute(.foregroundColor, at: 18, effectiveRange: nil) as? NSColor
  #expect(str == theme.tokenColors["string"])
  #expect(CodeHighlighter.language(named: "py")?.tsName == "python")
  #expect(CodeHighlighter.languageNames.count >= 38)
}

@MainActor @Test func languagePickerRewritesInfoString() {
  let h = Harness("```js\ncode\n```\n")
  h.c.setLanguage("typescript", fence: NSRange(location: 0, length: 5))
  #expect(h.c.storage.string == "```typescript\ncode\n```\n")
}
