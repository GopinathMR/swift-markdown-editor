import Testing

@testable import MarkdownEditorDemo

@MainActor @Test func sampleCoversTheFeatureTour() {
  let s = DemoSample.text
  for needle in ["# ", "```", "$$", "| ", "- [ ]", "[toc]", "[^1]", "```mermaid", "> [!TIP]"] {
    #expect(s.contains(needle), "sample lacks \(needle)")
  }
}
