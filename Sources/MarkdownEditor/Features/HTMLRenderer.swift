import AppKit

/// Model → HTML, from the same parse the editor uses, so export and editor never disagree.
/// Used for rich copy and for HTML/PDF/PNG export.
@MainActor
struct HTMLRenderer {
  let text: NSString
  let model: DocumentModel
  let preferences: EditorPreferences
  /// Rendered math/diagrams/images by request; missing ones fall back to source.
  var render: (RenderRequest) -> RenderResult? = { _ in nil }
  var resolveURL: (String) -> URL? = { _ in nil }
  /// Inline local images as data URIs (self-contained export).
  var embedImages = false
  var dark = false

  private var mathContext: MathContext {
    MathContext.build(model, text: text, numbering: preferences.mathNumbering)
  }

  /// Every render this document needs (export resolves them all first).
  func requests(fontSize: CGFloat) -> [RenderRequest] {
    var out: [RenderRequest] = []
    let ctx = mathContext
    for (b, off) in model.blocks(where: { _ in true }) {
      switch b.kind {
      case .math:
        let raw = b.content.map { text.substring(with: $0.shifted(by: off)) } ?? ""
        out.append(
          .math(
            latex: MathPreprocessor.prepare(raw, context: ctx, physics: preferences.physicsPackage),
            display: true, dark: dark, fontSize: fontSize * 1.15,
            number: ctx.numbers[off + b.range.location]))
      case .diagram(let kind):
        out.append(
          .diagram(
            kind, source: b.content.map { text.substring(with: $0.shifted(by: off)) } ?? "",
            dark: dark))
      default: break
      }
      forEachInline(Block(kind: .paragraph, range: b.range, inlines: b.inlines)) { i in
        if case .math(let latex) = i.kind {
          out.append(
            .math(
              latex: MathPreprocessor.prepare(
                latex, context: ctx, physics: preferences.physicsPackage), display: false,
              dark: dark, fontSize: fontSize, number: nil))
        }
      }
    }
    return out
  }

  func body(fontSize: CGFloat = 16) -> String {
    let ctx = mathContext
    var out = ""
    var footnotes: [(String, String)] = []
    for e in model.entries {
      if case .footnoteDefinition(let id) = e.block.kind {
        footnotes.append(
          (id, inlineHTML(e.block, offset: e.start, hidden: [], ctx: ctx, fontSize: fontSize)))
        continue
      }
      out += block(e.block, offset: e.start, hidden: [], ctx: ctx, fontSize: fontSize)
    }
    if !footnotes.isEmpty {
      let ordered = footnotes.sorted {
        (model.footnoteNumbers[$0.0] ?? 999) < (model.footnoteNumbers[$1.0] ?? 999)
      }
      out += "<section class=\"footnotes\"><hr><ol>"
      for (id, html) in ordered {
        out +=
          "<li id=\"fn:\(esc(id))\">\(html) <a href=\"#fnref:\(esc(id))\" class=\"footnote-back\">↩</a></li>"
      }
      out += "</ol></section>\n"
    }
    return out
  }

  // MARK: Blocks

  private func block(
    _ b: Block, offset: Int, hidden: [NSRange], ctx: MathContext, fontSize: CGFloat
  ) -> String {
    let abs = b.range.shifted(by: offset)
    switch b.kind {
    case .paragraph:
      return
        "<p>\(inlineHTML(b, offset: offset, hidden: hidden, ctx: ctx, fontSize: fontSize))</p>\n"
    case .heading(let l), .setextHeading(let l):
      let slug = model.headings.first { $0.range.location == abs.location }?.slug ?? ""
      return
        "<h\(l) id=\"\(esc(slug))\">\(inlineHTML(b, offset: offset, hidden: hidden, ctx: ctx, fontSize: fontSize))</h\(l)>\n"
    case .blockquote, .callout:
      // Quote markers and a callout's `[!TYPE]` never reach the HTML.
      let h =
        hidden + b.markers.map { $0.shifted(by: offset) }
        + [b.content?.shifted(by: offset)].compactMap { $0 }
      let inner = b.children.map {
        block($0, offset: offset, hidden: h, ctx: ctx, fontSize: fontSize)
      }.joined()
      if case .callout(let t) = b.kind {
        return
          "<div class=\"callout callout-\(t.rawValue.lowercased())\"><p class=\"callout-title\">\(t.title)</p>\(inner)</div>\n"
      }
      return "<blockquote>\n\(inner)</blockquote>\n"
    case .list:
      let ordered: Bool
      if case .listItem(let o, _) = b.children.first?.kind { ordered = o } else { ordered = false }
      let start =
        Int(b.children.first?.info?.trimmingCharacters(in: CharacterSet(charactersIn: ".)")) ?? "")
        ?? 1
      let items = b.children.map {
        block($0, offset: offset, hidden: hidden, ctx: ctx, fontSize: fontSize)
      }.joined()
      return ordered
        ? "<ol\(start != 1 ? " start=\"\(start)\"" : "")>\n\(items)</ol>\n"
        : "<ul>\n\(items)</ul>\n"
    case .listItem(_, let task):
      let box = task.map { "<input type=\"checkbox\" disabled\($0 ? " checked" : "")> " } ?? ""
      let tight = b.children.count == 1 && b.children[0].kind == .paragraph
      let inner =
        tight
        ? inlineHTML(b.children[0], offset: offset, hidden: hidden, ctx: ctx, fontSize: fontSize)
        : b.children.map { block($0, offset: offset, hidden: hidden, ctx: ctx, fontSize: fontSize) }
          .joined()
      return "<li\(task != nil ? " class=\"task\"" : "")>\(box)\(inner)</li>\n"
    case .code(let language):
      let code =
        b.content.map { text.substring(with: $0.shifted(by: offset)) } ?? text.substring(with: abs)
      let cls = language.map { " class=\"language-\(esc($0))\"" } ?? ""
      return
        "<pre><code\(cls)>\(esc(code.hasSuffix("\n") ? String(code.dropLast()) : code))</code></pre>\n"
    case .math:
      let raw = b.content.map { text.substring(with: $0.shifted(by: offset)) } ?? ""
      let req = RenderRequest.math(
        latex: MathPreprocessor.prepare(raw, context: ctx, physics: preferences.physicsPackage),
        display: true, dark: dark, fontSize: fontSize * 1.15, number: ctx.numbers[abs.location])
      if let r = render(req), let img = r.image, let uri = Self.dataURI(img) {
        return
          "<div class=\"math-block\"><img src=\"\(uri)\" alt=\"\(esc(raw))\" width=\"\(Int(r.size.width))\" height=\"\(Int(r.size.height))\"></div>\n"
      }
      return "<pre class=\"math-source\">$$\(esc(raw))$$</pre>\n"
    case .diagram(let kind):
      let src = b.content.map { text.substring(with: $0.shifted(by: offset)) } ?? ""
      if let svg = render(.diagram(kind, source: src, dark: dark))?.svg {
        return "<div class=\"diagram\">\(svg)</div>\n"
      }
      return "<pre><code>\(esc(src))</code></pre>\n"
    case .table:
      guard let t = TableModel(source: text.substring(with: abs)) else { return "" }
      func cell(_ tag: String, _ s: String, _ c: Int) -> String {
        let align: String
        switch t.alignments[c] {
        case .left: align = " style=\"text-align:left\""
        case .center: align = " style=\"text-align:center\""
        case .right: align = " style=\"text-align:right\""
        case .none: align = ""
        }
        return "<\(tag)\(align)>\(inlineMarkdown(s, ctx: ctx, fontSize: fontSize))</\(tag)>"
      }
      let head = t.header.enumerated().map { cell("th", $1, $0) }.joined()
      let rows = t.rows.map {
        "<tr>" + $0.enumerated().map { cell("td", $1, $0) }.joined() + "</tr>"
      }.joined(separator: "\n")
      return "<table>\n<thead><tr>\(head)</tr></thead>\n<tbody>\n\(rows)\n</tbody>\n</table>\n"
    case .thematicBreak:
      return "<hr>\n"
    case .pageBreak:
      return "<div style=\"page-break-after: always\"></div>\n"
    case .toc:
      var s = "<nav class=\"toc\"><ul>\n"
      let minLevel = model.headings.map(\.level).min() ?? 1
      for h in model.headings {
        s +=
          "<li class=\"toc-h\(h.level - minLevel + 1)\"><a href=\"#\(esc(h.slug))\">\(esc(h.title))</a></li>\n"
      }
      return s + "</ul></nav>\n"
    case .html:
      let src = text.substring(with: abs)
      if let tag = ImageTag.parse(src) {
        return "<p>" + imageHTML(tag.src, alt: tag.alt, size: tag.size) + "</p>\n"
      }
      return HTMLSanitizer.sanitize(src) + "\n"
    case .footnoteDefinition, .frontMatter, .comment, .linkReferenceDefinition:
      return ""
    }
  }

  // MARK: Inlines

  private func inlineHTML(
    _ b: Block, offset: Int, hidden: [NSRange], ctx: MathContext, fontSize: CGFloat
  ) -> String {
    var r = b.range.shifted(by: offset)
    let skip = hidden + b.markers.map { $0.shifted(by: offset) }
    while r.length > 0, [0x0A, 0x0D].contains(text.character(at: r.end - 1)) { r.length -= 1 }
    return span(r, b.inlines, offset: offset, skip: skip, ctx: ctx, fontSize: fontSize)
  }

  /// Markdown inside a table cell, parsed on its own.
  private func inlineMarkdown(_ s: String, ctx: MathContext, fontSize: CGFloat) -> String {
    let p = MarkdownParser(preferences: preferences)
    let m = p.parse(s as NSString).model
    guard let e = m.entries.first else { return esc(s) }
    let sub = HTMLRenderer(
      text: s as NSString, model: m, preferences: preferences, render: render,
      resolveURL: resolveURL, embedImages: embedImages, dark: dark)
    return sub.span(
      NSRange(location: 0, length: (s as NSString).length), e.block.inlines, offset: e.start,
      skip: [], ctx: ctx, fontSize: fontSize)
  }

  private func span(
    _ range: NSRange, _ inlines: [Inline], offset: Int, skip: [NSRange], ctx: MathContext,
    fontSize: CGFloat
  ) -> String {
    var out = ""
    var pos = range.location
    for i in inlines.sorted(by: { $0.range.location < $1.range.location }) {
      let r = i.range.shifted(by: offset)
      guard r.location >= pos, r.end <= range.end else { continue }
      out += plain(NSRange(location: pos, length: r.location - pos), skip: skip)
      out += inline(i, offset: offset, skip: skip, ctx: ctx, fontSize: fontSize)
      pos = r.end
    }
    out += plain(NSRange(location: pos, length: range.end - pos), skip: skip)
    return out
  }

  /// Text with `skip` ranges (quote markers, list indents) removed and hard breaks kept.
  private func plain(_ r: NSRange, skip: [NSRange]) -> String {
    guard r.length > 0 else { return "" }
    var s = ""
    var pos = r.location
    for k in skip.sorted(by: { $0.location < $1.location }) where k.end > pos && k.location < r.end
    {
      if k.location > pos {
        s += text.substring(with: NSRange(location: pos, length: k.location - pos))
      }
      pos = max(pos, k.end)
    }
    if pos < r.end { s += text.substring(with: NSRange(location: pos, length: r.end - pos)) }
    var html = esc(s)
    html = html.replacingOccurrences(
      of: #"(?: {2,}|\\)\r?\n"#, with: "<br>\n", options: .regularExpression)
    return html
  }

  private func content(_ i: Inline, offset: Int) -> NSRange {
    let r = i.range.shifted(by: offset)
    var start = r.location
    var end = r.end
    let ms = i.markers.map { $0.shifted(by: offset) }.sorted { $0.location < $1.location }
    for m in ms where m.location == start { start = m.end }
    for m in ms.reversed() where m.end == end && m.location >= start { end = m.location }
    return NSRange(location: start, length: max(0, end - start))
  }

  private func inline(
    _ i: Inline, offset: Int, skip: [NSRange], ctx: MathContext, fontSize: CGFloat
  ) -> String {
    let c = content(i, offset: offset)
    let inner = { span(c, i.children, offset: offset, skip: skip, ctx: ctx, fontSize: fontSize) }
    switch i.kind {
    case .emphasis: return "<em>\(inner())</em>"
    case .strong: return "<strong>\(inner())</strong>"
    case .strikethrough: return "<del>\(inner())</del>"
    case .highlight: return "<mark>\(inner())</mark>"
    case .superscript: return "<sup>\(inner())</sup>"
    case .subscript: return "<sub>\(inner())</sub>"
    case .code:
      return "<code>\(esc(text.substring(with: c).trimmingCharacters(in: .whitespaces)))</code>"
    case .link(let dest):
      let href = dest.hasPrefix("ref:") ? model.linkRefs[String(dest.dropFirst(4))] : dest
      guard let href else { return esc(text.substring(with: i.range.shifted(by: offset))) }
      return "<a href=\"\(esc(href))\">\(inner())</a>"
    case .autolink(let url):
      let label = text.substring(with: c)
      return "<a href=\"\(esc(url.hasPrefix("www.") ? "https://" + url : url))\">\(esc(label))</a>"
    case .image(let src, let alt):
      return imageHTML(src, alt: alt, size: i.size)
    case .math(let latex):
      let req = RenderRequest.math(
        latex: MathPreprocessor.prepare(latex, context: ctx, physics: preferences.physicsPackage),
        display: false, dark: dark, fontSize: fontSize, number: nil)
      if let r = render(req), let img = r.image, let uri = Self.dataURI(img) {
        return
          "<img class=\"math-inline\" src=\"\(uri)\" alt=\"\(esc(latex))\" width=\"\(Int(r.size.width))\" height=\"\(Int(r.size.height))\" style=\"vertical-align:-\(Int(r.descent))px\">"
      }
      return "<code class=\"math-source\">$\(esc(latex))$</code>"
    case .emoji(let e): return e
    case .footnoteRef(let id):
      guard let n = model.footnoteNumbers[id], model.footnoteDefinitions[id] != nil else {
        return esc(text.substring(with: i.range.shifted(by: offset)))
      }
      return
        "<sup class=\"footnote-ref\"><a href=\"#fn:\(esc(id))\" id=\"fnref:\(esc(id))\">\(n)</a></sup>"
    case .entity(let ch): return esc(ch)
    case .escape: return esc(text.substring(with: c))
    case .html:
      let r = i.range.shifted(by: offset)
      if i.markers.count == 2 {
        let open = text.substring(with: i.markers[0].shifted(by: offset))
        let close = text.substring(with: i.markers[1].shifted(by: offset))
        return HTMLSanitizer.sanitize(open + "\u{E000}" + close).replacingOccurrences(
          of: "\u{E000}", with: inner())
      }
      let tag = text.substring(with: r)
      return tag.lowercased().hasPrefix("<br") ? "<br>" : ""
    case .comment: return ""
    }
  }

  private func imageHTML(_ src: String, alt: String, size: String?) -> String {
    var s = src
    if embedImages, let url = resolveURL(src), url.isFileURL, let data = try? Data(contentsOf: url)
    {
      let ext = url.pathExtension.lowercased()
      let mime =
        ext == "svg"
        ? "image/svg+xml"
        : ext == "jpg" || ext == "jpeg" ? "image/jpeg" : "image/\(ext.isEmpty ? "png" : ext)"
      s = "data:\(mime);base64," + data.base64EncodedString()
    } else if let url = resolveURL(src), url.isFileURL, !embedImages {
      s = url.absoluteString
    }
    var attrs = ""
    if let size {
      attrs =
        size.hasPrefix("zoom:") ? " style=\"zoom:\(size.dropFirst(5))\"" : " width=\"\(esc(size))\""
    }
    return "<img src=\"\(esc(s))\" alt=\"\(esc(alt))\"\(attrs)>"
  }

  static func dataURI(_ image: NSImage) -> String? {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
    else { return nil }
    return "data:image/png;base64," + png.base64EncodedString()
  }

  func esc(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
  }
}
