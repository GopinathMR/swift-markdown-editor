import AppKit
import Testing

@testable import MarkdownEditor

let sample = """
  ---
  title: Sample
  ---
  # Heading *one*

  Para with **bold**, `code`, ~~strike~~ and [a link](https://example.com).

  > [!NOTE]
  > A callout.

  - [ ] task
  - item
    1. nested

  | a | b |
  |:--|--:|
  | 1 | 2 |

  ```swift
  let x = 1
  ```

  $$
  E = mc^2
  $$

  [toc]

  Footnote ref[^1].

  [^1]: The note.

  ***
  """

@MainActor
func kinds(_ m: DocumentModel) -> [BlockKind] { m.entries.map(\.block.kind) }

@MainActor @Test func parsesTyporaBlocks() {
  let p = MarkdownParser(preferences: .init())
  let m = p.parse(sample as NSString).model
  #expect(
    kinds(m) == [
      .frontMatter, .heading(1), .paragraph, .callout(.note), .list, .table,
      .code(language: "swift"), .math, .toc,
      .paragraph, .footnoteDefinition("1"), .thematicBreak,
    ])
  #expect(m.headings.map(\.slug) == ["heading-one"])
  #expect(m.footnoteNumbers == ["1": 1])
  #expect(m.frontMatter?.contains("title: Sample") == true)
}

@MainActor @Test func inlineMarkersAreExact() {
  let p = MarkdownParser(preferences: .init())
  let text = "Para **bold** [l](u) `c`" as NSString
  let m = p.parse(text).model
  let inlines = m.entries[0].block.inlines
  let strong = inlines.first { $0.kind == .strong }!
  #expect(strong.markers.map { text.substring(with: $0) } == ["*", "*", "*", "*"])
  let link = inlines.first { if case .link = $0.kind { return true } else { return false } }!
  #expect(link.kind == .link("u"))
  #expect(link.markers.map { text.substring(with: $0) } == ["[", "](u)"])
}

@MainActor @Test func extensionsFollowPreferences() {
  var prefs = EditorPreferences()
  let text = "a ==hi== x^2^ H~2~O $x$ :smile: ###Head" as NSString
  var m = MarkdownParser(preferences: prefs).parse(text).model
  let off = m.entries[0].block.inlines.map(\.kind)
  #expect(!off.contains(.highlight))
  #expect(off.contains(.emoji("😄")))
  prefs.highlight = true
  prefs.superscript = true
  prefs.subscript = true
  prefs.inlineMath = true
  m = MarkdownParser(preferences: prefs).parse(text).model
  let on = m.entries[0].block.inlines.map(\.kind)
  #expect(on.contains(.highlight))
  #expect(on.contains(.superscript))
  #expect(on.contains(.subscript))
  #expect(on.contains(.math("x")))
}

@MainActor @Test func nonStrictHeadingAndPandocMath() {
  var prefs = EditorPreferences()
  prefs.inlineMath = true
  let m = MarkdownParser(preferences: prefs).parse(
    "###Title\n\nIt costs $5 and $6 today." as NSString
  ).model
  #expect(m.entries[0].block.kind == .heading(3))
  #expect(
    !m.entries[1].block.inlines.contains {
      if case .math = $0.kind { return true } else { return false }
    })
  prefs.strictMode = true
  let strict = MarkdownParser(preferences: prefs).parse("###Title" as NSString).model
  #expect(strict.entries[0].block.kind == .paragraph)
}

/// Incremental reparse must agree with a fresh parse, edit after edit.
@MainActor @Test func incrementalMatchesFullParse() {
  let p = MarkdownParser(preferences: .init())
  var text = sample
  _ = p.parse(text as NSString)
  var rng = SystemRandomNumberGenerator()
  let inserts = ["x", "\n", "**", "# ", "```\n", "- ", "> ", " ", "|", "$$\n"]
  for _ in 0..<600 {
    let ns = text as NSString
    let loc = Int.random(in: 0...ns.length, using: &rng)
    let edited: NSRange
    let delta: Int
    if Bool.random(using: &rng), loc < ns.length {
      let len = min(Int.random(in: 1...3, using: &rng), ns.length - loc)
      text = ns.replacingCharacters(in: NSRange(location: loc, length: len), with: "")
      edited = NSRange(location: loc, length: 0)
      delta = -len
    } else {
      let ins = inserts.randomElement(using: &rng)!
      text = ns.replacingCharacters(in: NSRange(location: loc, length: 0), with: ins)
      edited = NSRange(location: loc, length: (ins as NSString).length)
      delta = (ins as NSString).length
    }
    let inc = p.update(text as NSString, editedRange: edited, delta: delta).model
    let full = MarkdownParser(preferences: .init()).parse(text as NSString).model
    #expect(inc.entries.map(\.start) == full.entries.map(\.start))
    #expect(inc.entries.map(\.block) == full.entries.map(\.block))
    if inc.entries.map(\.block) != full.entries.map(\.block) { break }
  }
}

@MainActor @Test func parsesLargeDocumentQuickly() {
  var s = ""
  for i in 0..<20000 {
    s +=
      i % 10 == 0
      ? "## Heading \(i)\n\n" : "Some **bold** text with `code` and [link](http://x) number \(i).\n"
  }
  let p = MarkdownParser(preferences: .init())
  let t0 = Date()
  let m = p.parse(s as NSString).model
  let full = Date().timeIntervalSince(t0)
  let mid = (s as NSString).length / 2
  let s2 = (s as NSString).replacingCharacters(in: NSRange(location: mid, length: 0), with: "x")
  let t1 = Date()
  let r = p.update(s2 as NSString, editedRange: NSRange(location: mid, length: 1), delta: 1)
  let inc = Date().timeIntervalSince(t1)
  print(
    "20k lines: full \(Int(full * 1000))ms, incremental \(Int(inc * 1000))ms, changed \(r.changed.count)/\(m.entries.count)"
  )
  #expect(r.changed.count <= 3)
}
