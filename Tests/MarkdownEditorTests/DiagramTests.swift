import AppKit
import Testing

@testable import MarkdownEditor

@MainActor @Test func rendersMermaidFlowAndSequence() async {
  let m = await DiagramRenderer.shared.render(.mermaid, source: "graph LR\n  A --> B", dark: false)
  #expect(m.error == nil)
  #expect(m.image != nil && m.size.width > 40)
  #expect(m.svg?.hasPrefix("<svg") == true)
  let f = await DiagramRenderer.shared.render(
    .flow, source: "st=>start: Start\ne=>end: End\nst->e", dark: true)
  #expect(f.error == nil && f.image != nil)
  let s = await DiagramRenderer.shared.render(.sequence, source: "Alice->Bob: Hello", dark: false)
  #expect(s.error == nil && s.image != nil)
}

@MainActor @Test func diagramErrorsComeBackAsMessages() async {
  let bad = await DiagramRenderer.shared.render(.mermaid, source: "graph LR\n  A -->", dark: false)
  #expect(bad.image == nil)
  #expect(bad.error?.isEmpty == false)
}
