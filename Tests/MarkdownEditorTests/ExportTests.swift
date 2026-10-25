import AppKit
import PDFKit
import Testing

@testable import MarkdownEditor

let exportSample = """
  ---
  title: Export Test
  author: Ada
  ---
  # Report

  Some **bold** text with a footnote[^1] and math $x^2$.

  > [!NOTE]
  > Callout body.

  - [x] done
  - [ ] todo

  | a | b |
  |:-:|--:|
  | 1 | 2 |

  $$
  E = mc^2
  $$

  ```mermaid
  graph LR
    A --> B
  ```

  <div style="page-break-after: always"></div>

  # Second chapter

  [^1]: The note.
  """

@MainActor func exportHarness() -> Harness {
  var p = EditorPreferences()
  p.inlineMath = true
  p.frontMatterOverridesExport = true
  return Harness(exportSample, prefs: p)
}

@MainActor @Test func htmlExportIsSelfContained() async throws {
  let h = exportHarness()
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString + ".html")
  try await Exporter(coordinator: h.c).export(.html(styled: true), to: url, options: .init())
  let html = try String(contentsOf: url, encoding: .utf8)
  #expect(html.contains("<title>Export Test</title>"))  // front matter wins
  #expect(html.contains("<strong>bold</strong>"))
  #expect(html.contains("class=\"callout callout-note\""))
  #expect(html.contains("<input type=\"checkbox\" disabled checked>"))
  #expect(html.contains("<th style=\"text-align:center\">a</th>"))
  #expect(html.contains("data:image/png;base64,"))  // math
  #expect(html.contains("<svg"))  // mermaid
  #expect(html.contains("id=\"fn:1\""))
  #expect(!html.contains("[!NOTE]"))
  #expect(!html.contains("title: Export Test"))
  let plain = try await Exporter(coordinator: h.c).html(styled: false, options: .init())
  #expect(!plain.contains("<style>\n:root"))  // no theme CSS (Mermaid SVGs carry their own)
}

@MainActor @Test func pdfExportPaginatesAndStamps() async throws {
  let h = exportHarness()
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString + ".pdf")
  var o = ExportOptions()
  o.header = "${title} by ${author}"
  try await Exporter(coordinator: h.c).export(.pdf, to: url, options: o)
  let doc = try #require(PDFDocument(url: url))
  #expect(doc.pageCount >= 2)  // the page-break div
  #expect(doc.page(at: 0)?.string?.contains("1 / \(doc.pageCount)") == true)
  #expect(doc.page(at: 0)?.string?.contains("Export Test by Ada") == true)
  #expect((doc.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String) == "Ada")
}

@MainActor @Test func pngExportSnapshotsTheDocument() async throws {
  let h = exportHarness()
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString + ".png")
  try await Exporter(coordinator: h.c).export(.png, to: url, options: .init())
  let img = try #require(NSImage(contentsOf: url))
  #expect(img.size.width >= 600 && img.size.height > 400)
}

@MainActor @Test(.enabled(if: Exporter.pandocURL != nil)) func pandocExportWritesDocx() async throws
{
  let h = exportHarness()
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString + ".docx")
  try await Exporter(coordinator: h.c).export(.pandoc(.docx), to: url, options: .init())
  #expect(try Data(contentsOf: url).count > 1000)
}

@MainActor @Test func inlineHTMLSurvivesExport() {
  let s = "a <u>b</u> c <span style=\"color:red\">d</span>\n" as NSString
  let m = MarkdownParser(preferences: .init()).parse(s).model
  #expect(
    HTMLRenderer(text: s, model: m, preferences: .init()).body()
      == "<p>a <u>b</u> c <span style=\"color:red\">d</span></p>\n")
}
