import AppKit
import Testing

@testable import MarkdownEditor

/// ~1 MB: 20 000 lines with headings, prose, lists, code, 200 math blocks, 50 diagrams.
func largeFixture() -> String {
  var s = "---\ntitle: Big\n---\n\n"
  var line = 0
  var i = 0
  while line < 20000 {
    switch i % 40 {
    case 0:
      s += "## Section \(i)\n\n"
      line += 2
    case 7:
      s += "$$\n\\int_0^{\(i)} x^2 dx\n$$\n\n"
      line += 4
    case 13 where i % 160 == 13:
      s += "```mermaid\ngraph LR\n  A\(i) --> B\(i)\n```\n\n"
      line += 5
    case 19:
      s += "- item **\(i)** with `code`\n- [ ] task \(i)\n\n"
      line += 3
    case 27:
      s += "```swift\nlet v\(i) = \(i)\n```\n\n"
      line += 4
    default:
      s +=
        "Paragraph \(i) has *emphasis*, a [link](https://example.com/\(i)), some inline $a_\(i)$ and plain words to fill it out nicely.\n"
      line += 1
    }
    i += 1
  }
  return s
}

@MainActor @Test(.timeLimit(.minutes(2))) func largeDocumentOpensAndTypesFast() {
  let text = largeFixture()
  print(
    "fixture: \((text as NSString).length) UTF-16, \(text.components(separatedBy: "\n").count) lines"
  )
  var p = EditorPreferences()
  p.inlineMath = true
  let t0 = Date()
  let h = Harness(text, prefs: p)
  let open = Date().timeIntervalSince(t0)
  // Type in the middle of the document, one keystroke at a time.
  let mid = (text as NSString).range(of: "Paragraph 1001 ").location
  h.caret(mid)
  var times: [Double] = []
  for ch in "typing fast" {
    let k0 = Date()
    h.tv.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0))
    times.append(Date().timeIntervalSince(k0) * 1000)
  }
  times.sort()
  let p95 = times[Int(Double(times.count - 1) * 0.95)]
  print(
    String(
      format: "open %.0f ms, keystroke median %.1f ms, p95 %.1f ms", open * 1000,
      times[times.count / 2], p95))
  #expect(h.c.storage.string.count == text.count + 11)
  #if !DEBUG
    // The spec budget is 1 MB in < 1 s and a 16 ms p95 keystroke; this fixture is 1.9 MB.
    #expect(open < 1.5)
    #expect(p95 < 16)
  #endif
}
