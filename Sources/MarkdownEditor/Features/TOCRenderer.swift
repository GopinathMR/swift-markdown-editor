import AppKit

/// `[toc]`: the document's headings, drawn as a block, with row rects for click-to-jump.
@MainActor
enum TOCRenderer {
  private static var cache:
    (key: String, value: (image: NSImage?, size: CGSize, rows: [(CGRect, String)]))?

  static func image(_ headings: [HeadingInfo], theme: ResolvedTheme, width: CGFloat) -> (
    image: NSImage?, size: CGSize, rows: [(CGRect, String)]
  ) {
    let key =
      headings.map { "\($0.level)\u{1}\($0.title)\u{1}\($0.number ?? "")" }.joined(
        separator: "\u{2}")
      + "|\(theme.isDark)|\(Int(width))|\(theme.body.pointSize)|\(theme.style.headingNumbering)"
    if let c = cache, c.key == key { return c.value }
    let font = theme.body
    let lineHeight = ceil(font.ascender - font.descender + font.leading) + 6
    let minLevel = headings.map(\.level).min() ?? 1
    var rows: [(CGRect, String)] = []
    var y: CGFloat = 4
    var lines: [(NSAttributedString, CGPoint)] = []
    for h in headings {
      let indent = CGFloat(h.level - minLevel) * 1.4 * font.pointSize
      let title =
        (theme.style.headingNumbering ? (h.number.map { $0 + " " } ?? "") : "")
        + (h.title.isEmpty ? "Untitled" : h.title)
      let s = NSAttributedString(
        string: title,
        attributes: [
          .font: h.level == minLevel ? theme.font(bold: true, italic: false) : font,
          .foregroundColor: theme.link,
        ])
      let w = min(width - indent, ceil(s.size().width))
      lines.append((s, CGPoint(x: indent, y: y)))
      rows.append((CGRect(x: indent, y: y, width: max(w, 20), height: lineHeight), h.slug))
      y += lineHeight
    }
    if headings.isEmpty {
      lines.append(
        (
          NSAttributedString(
            string: "Table of contents (no headings yet)",
            attributes: [.font: font, .foregroundColor: theme.secondary]), CGPoint(x: 0, y: y)
        ))
      y += lineHeight
    }
    let size = CGSize(width: max(1, width), height: y + 4)
    let image = NSImage(size: size, flipped: true) { _ in
      for (s, p) in lines { s.draw(at: CGPoint(x: p.x, y: p.y + 3)) }
      return true
    }
    let value = (Optional(image), size, rows)
    cache = (key, value)
    return value
  }
}
