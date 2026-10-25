import AppKit

extension NSAttributedString.Key {
  /// `InlineDecoration` drawn at the first character of the run (over hidden/clear text).
  static let mdInline = NSAttributedString.Key("md.inline")
  /// `BlockDecoration` for the whole paragraph (one line of source).
  static let mdBlock = NSAttributedString.Key("md.block")
  /// Link destination for ⌘-click. Not `.link`: NSTextView would open that on a plain click.
  static let mdLink = NSAttributedString.Key("md.link")
  /// Marks hidden syntax so find and accessibility can skip it.
  static let mdHidden = NSAttributedString.Key("md.hidden")
  /// `TaskBox` hit target: toggles `[ ]`/`[x]` at this source range.
  static let mdTask = NSAttributedString.Key("md.task")
}

/// Something drawn in place of source characters.
final class InlineDecoration: NSObject {
  enum Kind {
    case text(String, NSFont, NSColor, raise: CGFloat)
    case checkbox(checked: Bool, color: NSColor)
    case image(NSImage, size: CGSize, baseline: CGFloat)
  }
  let kind: Kind
  /// Horizontal offset from the character's position (list bullets sit left of the text).
  let dx: CGFloat
  init(_ kind: Kind, dx: CGFloat = 0) {
    self.kind = kind
    self.dx = dx
  }

  var width: CGFloat {
    switch kind {
    case .text(let s, let f, _, _): return (s as NSString).size(withAttributes: [.font: f]).width
    case .checkbox: return 18
    case .image(_, let size, _): return size.width
    }
  }
}

/// Drawn behind/around one paragraph (= one source line).
final class BlockDecoration: NSObject {
  /// Full-width background (code, front matter, math source).
  var background: NSColor?
  var roundTop = false
  var roundBottom = false
  /// Quote bars: x positions (in container coordinates) and colours.
  var bars: [(x: CGFloat, color: NSColor)] = []
  /// Horizontal rule drawn across the paragraph's spacing area.
  var rule: NSColor?
  var ruleDashed = false
  var ruleLabel: String?
  /// Rendered block (math, diagram, image, HTML) drawn in the paragraph-spacing area after the line.
  var render: NSImage?
  var renderSize: CGSize = .zero
  var renderCentered = true
  var renderError: String?
  /// Language label (top-right of a code block) and line number gutter.
  var label: String?
  var labelColor: NSColor = .secondaryLabelColor
  var lineNumber: Int?
  var gutterFont: NSFont?
  /// Heading auto-number drawn in the first-line indent.
  var prefix: (String, NSFont, NSColor)?
  /// Focus-mode/inset left edge of the background box.
  var inset: CGFloat = 0
}
