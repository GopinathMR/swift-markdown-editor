import AppKit

/// Syntax colours for fenced code (filled in by the code-blocks layer).
@MainActor
final class CodeHighlighter {
  func highlight(_ code: String, language: String, colors: [String: NSColor]) -> [(
    NSRange, NSColor
  )] { [] }
}
