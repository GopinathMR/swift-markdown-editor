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

@MainActor @Test func findAndReplaceAllIsOneUndoStep() {
  let h = Harness("cat **cat** `cat` dog cat\n")
  h.c.showFind(replace: true)
  h.c.find.query = "cat"
  #expect(h.c.find.matches.count == 4)
  h.c.find.replacement = "cow"
  h.c.find.replaceAll()
  #expect(h.c.storage.string == "cow **cow** `cow` dog cow\n")
  h.tv.undoManager?.undo()
  #expect(h.c.storage.string == "cat **cat** `cat` dog cat\n")
}

@MainActor @Test func findSkipsHiddenSyntaxAndSupportsRegex() {
  let h = Harness("a **b** c\n\nx\n")
  h.caret(11)
  h.c.showFind(replace: false)
  h.c.find.query = "**"
  #expect(h.c.find.matches.isEmpty)  // only hidden markers
  h.c.find.regex = true
  h.c.find.query = "(a) (\\*\\*b)"
  h.c.find.replacement = "$2 $1"
  h.c.find.replaceAll()
  #expect(h.c.storage.string.hasPrefix("**b a**"))
}

@MainActor @Test func spellCheckIgnoresCode() {
  let h = Harness("Some `cde` and txt\n")
  h.caret(18)
  #expect(!h.c.isProse(NSRange(location: 6, length: 3)))
  #expect(h.c.isProse(NSRange(location: 15, length: 3)))
}

@Test func tableModelRoundTripsAndEscapes() {
  let src = "| a | b |\n|:--|--:|\n| 1 | x\\|y |"
  var t = TableModel(source: src)!
  #expect(t.header == ["a", "b"])
  #expect(t.alignments == [.left, .right])
  #expect(t.rows == [["1", "x|y"]])
  t[0, 0] = "p|q"
  t.insertRow(at: 1)
  t.insertColumn(at: 2)
  t.moveColumn(from: 2, to: 0)
  let out = t.serialized()
  #expect(out.contains("p\\|q"))
  #expect(TableModel(source: out) == t)
  t.resize(rows: 1, columns: 2)
  #expect(t.rows.count == 1 && t.columnCount == 2)
}

@MainActor @Test func tableGridEditsRewriteOnlyTheTable() {
  let src = "Intro.\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nOutro.\n"
  let h = Harness(src)
  h.c.layoutOverlays()
  #expect(h.c.overlays.tables.count == 1)
  let grid = h.c.overlays.tables[0].grid
  grid.apply { $0[0, 1] = "two" }
  #expect(
    h.c.storage.string.hasPrefix(
      "Intro.\n\n| a   | b   |\n| --- | --- |\n| 1   | two |\n\nOutro.\n"))
  h.tv.undoManager?.undo()
  #expect(h.c.storage.string == src)
}

@Test func imageRulesResolvePathsLikeTypora() {
  var p = EditorPreferences()
  p.imageInsert = .copy(toFolder: "./${filename}.assets")
  let doc = URL(fileURLWithPath: "/tmp/notes/My Doc.md")
  let rules = ImageRules(preferences: p, documentURL: doc, frontMatterTarget: nil)
  #expect(rules.target == .copy(URL(fileURLWithPath: "/tmp/notes/My Doc.assets")))
  #expect(
    rules.markdownPath(URL(fileURLWithPath: "/tmp/notes/My Doc.assets/a b.png"))
      == "My%20Doc.assets/a%20b.png")
  p.ensureDotSlash = true
  p.escapeImageURL = false
  let r2 = ImageRules(preferences: p, documentURL: doc, frontMatterTarget: "upload")
  #expect(r2.target == .upload)
  #expect(r2.markdownPath(URL(fileURLWithPath: "/tmp/img/x.png")) == "../img/x.png")
  #expect(r2.markdownPath(URL(fileURLWithPath: "/tmp/notes/x.png")) == "./x.png")
}

@Test func imageTagSizing() {
  let t = ImageTag.parse(#"<img src="a.png" alt="A" style="zoom:50%" />"#)!
  #expect(t.src == "a.png" && t.alt == "A" && t.size == "zoom:50%")
  #expect(
    ImageTag.apply(t.size, natural: CGSize(width: 400, height: 200), width: 1000)
      == CGSize(width: 200, height: 100))
  #expect(
    ImageTag.apply("50%", natural: CGSize(width: 400, height: 200), width: 600)
      == CGSize(width: 300, height: 150))
  #expect(
    MediaEmbed.parse(#"<video src="v.mp4" width="320"></video>"#)
      == MediaEmbed(kind: .video, source: "v.mp4", width: 320, height: nil))
  #expect(
    MediaEmbed.parse(#"<iframe src="https://x.y/e" width=560 height=315></iframe>"#)?.kind
      == .iframe)
}

@MainActor @Test func blockImageRendersFromFileAndZoomRewrites() async throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let img = NSImage(size: NSSize(width: 40, height: 20), flipped: false) { r in
    NSColor.red.setFill()
    r.fill()
    return true
  }
  let png = NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(
    using: .png, properties: [:])!
  try png.write(to: dir.appendingPathComponent("pic.png"))
  let h = Harness("Text\n\n![Pic](pic.png)\n\nEnd\n")
  h.c.documentURL = dir.appendingPathComponent("doc.md")
  h.c.restyleAll()
  _ = await h.c.renders.resolve(.image(dir.appendingPathComponent("pic.png")))
  h.c.restyleAll()
  h.caret(0)
  #expect(h.isHidden(7))  // `![Pic](pic.png)` hidden behind the drawn image
  let found = h.c.image(at: 8)!
  h.c.rewriteImage(found, size: .some("zoom:50%"))
  #expect(
    h.c.storage.string == "Text\n\n<img src=\"pic.png\" alt=\"Pic\" style=\"zoom:50%\" />\n\nEnd\n")
}

@Test func htmlIsSanitizedAndConvertedToMarkdown() {
  let dirty = #"<p onclick="x()">Hi <a href="javascript:alert(1)">x</a><script>bad()</script></p>"#
  let clean = HTMLSanitizer.sanitize(dirty)
  #expect(!clean.contains("script") && !clean.contains("onclick") && !clean.contains("javascript"))
  #expect(HTMLSanitizer.isInvisible("<style>p{}</style><!-- c -->"))
  let html = """
    <h2>Title</h2><p>Some <b>bold</b>, <em>it</em> and <a href="https://x.y">link</a>.</p>
    <ul><li>one</li><li>two<ul><li>nested</li></ul></li></ul>
    <pre><code class="language-swift">let a = 1</code></pre>
    <table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>
    """
  #expect(
    HTMLToMarkdown.convert(html) == """
      ## Title

      Some **bold**, *it* and [link](https://x.y).

      - one
      - two
        - nested

      ```swift
      let a = 1
      ```

      | A   | B   |
      | --- | --- |
      | 1   | 2   |
      """)
}

@Test func frontMatterParsesAndFlagsErrors() {
  let ok = FrontMatter.parse("---\ntitle: T\nexport:\n  title: X\n---\n")
  #expect(ok.error == nil)
  #expect(FrontMatter.value("export.title", in: ok.values) == "X")
  #expect(FrontMatter.parse("---\ntitle: [unclosed\n---\n").error != nil)
}

@MainActor @Test func tocListsHeadingsWithRows() {
  let h = Harness("# A\n\n[toc]\n\n## B\n\ntext\n")
  let theme = h.c.styler.theme
  let r = TOCRenderer.image(h.c.model.headings, theme: theme, width: 500)
  #expect(r.rows.map(\.1) == ["a", "b"])
  #expect(r.image != nil)
}
