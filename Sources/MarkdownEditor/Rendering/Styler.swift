import AppKit

public enum EditorMode: Sendable, Equatable { case rendered, source }

/// Model + caret → attributes on the source text. Rendering is presentation only: hidden
/// syntax gets a near-zero clear font, substitutes are `mdInline` decorations, and blocks
/// reserve space with paragraph spacing for `mdBlock` renders.
@MainActor
final class Styler {
  var theme: ResolvedTheme
  var preferences: EditorPreferences
  var mode: EditorMode = .rendered
  var model = DocumentModel() {
    didSet { mathContextCache = nil }
  }
  private var mathContextCache: MathContext?

  private var mathContext: MathContext {
    if let c = mathContextCache { return c }
    let c = MathContext.build(model, text: text, numbering: preferences.mathNumbering)
    mathContextCache = c
    return c
  }
  var selection = NSRange(location: 0, length: 0)
  var containerWidth: CGFloat = 700
  var documentURL: URL?
  let renders: RenderCache
  var highlighter: CodeHighlighter?

  static let hiddenFont = NSFont.systemFont(ofSize: 0.01)

  init(theme: ResolvedTheme, preferences: EditorPreferences, renders: RenderCache) {
    self.theme = theme
    self.preferences = preferences
    self.renders = renders
  }

  // MARK: Output

  private var text: NSString = ""
  private var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
  private var lineDecos: [Int: BlockDecoration] = [:]
  private var lineStyles: [Int: ParaSpec] = [:]
  private var paraCache: [ParaSpec: NSParagraphStyle] = [:]

  struct ParaSpec: Hashable {
    var first: CGFloat = 0
    var head: CGFloat = 0
    var before: CGFloat = 0
    var after: CGFloat = 0
    var lineSpacing: CGFloat = 0
    var minHeight: CGFloat = 0
    var center = false
  }

  /// Restyle the entries at `indices` (and the text between them and the next entry).
  func apply(_ indices: IndexSet, to storage: NSTextStorage) {
    text = storage.string as NSString
    let entries = model.entries
    storage.beginEditing()
    defer { storage.endEditing() }
    if entries.isEmpty {
      let all = NSRange(location: 0, length: text.length)
      if all.length > 0 { storage.setAttributes(baseAttributes(), range: all) }
      return
    }
    for i in indices where i < entries.count {
      let start = i == 0 ? 0 : entries[i].start
      let end = i + 1 < entries.count ? entries[i + 1].start : text.length
      guard end > start else { continue }
      let full = NSRange(location: start, length: end - start)
      runs.removeAll(keepingCapacity: true)
      lineDecos.removeAll(keepingCapacity: true)
      lineStyles.removeAll(keepingCapacity: true)
      forEachLine(full) { line in lineStyles[line.location] = baseSpec }
      if mode == .source {
        styleSource(entries[i], index: i)
      } else {
        styleBlock(
          entries[i].block, offset: entries[i].start, ctx: Ctx(), siblingIndex: 0, siblings: [])
      }
      storage.setAttributes(baseAttributes(), range: full)
      for (r, a) in runs where r.length > 0 && r.end <= text.length {
        storage.addAttributes(a, range: r)
      }
      for (loc, spec) in lineStyles where loc < text.length {
        let line = text.lineRange(for: NSRange(location: loc, length: 0))
        storage.addAttribute(.paragraphStyle, value: para(spec), range: line)
      }
      for (loc, deco) in lineDecos where loc < text.length {
        let line = text.lineRange(for: NSRange(location: loc, length: 0))
        storage.addAttribute(.mdBlock, value: deco, range: line)
      }
    }
  }

  func baseAttributes() -> [NSAttributedString.Key: Any] {
    if mode == .source {
      return [
        .font: theme.mono, .foregroundColor: theme.text,
        .paragraphStyle: para(ParaSpec(lineSpacing: 3 * theme.zoom)),
      ]
    }
    return [.font: theme.body, .foregroundColor: theme.text, .paragraphStyle: para(baseSpec)]
  }

  private var baseSpec: ParaSpec {
    ParaSpec(
      after: theme.style.paragraphSpacing * theme.zoom,
      lineSpacing: theme.style.lineSpacing * theme.zoom)
  }

  private func para(_ s: ParaSpec) -> NSParagraphStyle {
    if let p = paraCache[s] { return p }
    let p = NSMutableParagraphStyle()
    p.firstLineHeadIndent = s.first
    p.headIndent = s.head
    p.paragraphSpacingBefore = s.before
    p.paragraphSpacing = s.after
    p.lineSpacing = s.lineSpacing
    p.minimumLineHeight = s.minHeight
    if s.center { p.alignment = .center }
    paraCache[s] = p
    return p
  }

  private func add(_ r: NSRange, _ a: [NSAttributedString.Key: Any]) { runs.append((r, a)) }

  private func hide(_ r: NSRange) {
    add(r, [.font: Self.hiddenFont, .foregroundColor: NSColor.clear, .mdHidden: true, .kern: 0])
  }

  private func dim(_ r: NSRange) { add(r, [.foregroundColor: theme.secondary]) }

  private func revealed(_ r: NSRange) -> Bool { r.touches(selection) }

  private func forEachLine(_ r: NSRange, _ f: (NSRange) -> Void) {
    var loc = r.location
    let end = max(r.end, r.location + 1)
    while loc < end, loc < text.length {
      let line = text.lineRange(for: NSRange(location: loc, length: 0))
      f(line)
      loc = line.end
    }
    if text.length == 0 || (r.location == text.length) {
      f(NSRange(location: text.length, length: 0))
    }
  }

  private func deco(_ lineStart: Int) -> BlockDecoration {
    let line = text.lineRange(
      for: NSRange(location: min(lineStart, max(0, text.length - 1)), length: 0))
    if let d = lineDecos[line.location] { return d }
    let d = BlockDecoration()
    lineDecos[line.location] = d
    return d
  }

  private func lineStart(_ loc: Int) -> Int {
    text.lineRange(for: NSRange(location: min(loc, max(0, text.length - 1)), length: 0)).location
  }

  private func spec(_ loc: Int, _ f: (inout ParaSpec) -> Void) {
    let l = lineStart(loc)
    var s = lineStyles[l] ?? baseSpec
    f(&s)
    lineStyles[l] = s
  }

  private func specLines(_ r: NSRange, _ f: (inout ParaSpec) -> Void) {
    forEachLine(r) { line in spec(line.location, f) }
  }

  /// Hide whole lines and collapse their spacing.
  private func hideLines(_ r: NSRange) {
    hide(r)
    specLines(r) { s in
      s.before = 0
      s.after = 0
      s.lineSpacing = 0
      s.minHeight = 0
    }
  }

  // MARK: Blocks

  struct Ctx {
    var indent: CGFloat = 0
    var quoteDepth = 0
    var listDepth = 0
    var bars: [(x: CGFloat, color: NSColor)] = []
    var textColor: NSColor?
    var inList = false
  }

  private func applyCtx(_ r: NSRange, _ ctx: Ctx) {
    specLines(r) { s in
      s.first = ctx.indent
      s.head = ctx.indent
      if ctx.inList { s.after = 4 * theme.zoom }
    }
    if !ctx.bars.isEmpty {
      forEachLine(r) { line in deco(line.location).bars = ctx.bars }
    }
    if let c = ctx.textColor { add(r, [.foregroundColor: c]) }
  }

  private func styleBlock(_ b: Block, offset: Int, ctx: Ctx, siblingIndex: Int, siblings: [Block]) {
    let abs = b.range.shifted(by: offset)
    let blockRevealed = revealed(abs)
    switch b.kind {
    case .paragraph:
      if let img = soleImage(b, offset: offset), renderBlockImage(img, block: abs, ctx: ctx) {
        return
      }
      applyCtx(abs, ctx)
      styleInlines(b.inlines, offset: offset, font: Font())

    case .heading(let level), .setextHeading(let level):
      applyCtx(abs, ctx)
      add(abs, [.font: theme.headingFont(level), .foregroundColor: ctx.textColor ?? theme.heading])
      specLines(abs) { s in
        s.before = (level <= 2 ? 0.8 : 0.5) * theme.body.pointSize
        s.after = 0.4 * theme.body.pointSize
      }
      for m in b.markers {
        let r = m.shifted(by: offset)
        if case .setextHeading = b.kind {
          if blockRevealed {
            dim(r)
          } else {
            hideLines(NSRange(location: r.location + 1, length: max(0, r.length - 1)))
          }
        } else if blockRevealed {
          dim(r)
        } else {
          hide(r)
        }
      }
      if theme.style.headingNumbering,
        let h = model.headings.first(where: { $0.range.location == offset + b.range.location }),
        let n = h.number
      {
        deco(abs.location).prefix = (n + " ", theme.headingFont(level), theme.secondary)
      }
      styleInlines(
        b.inlines, offset: offset, font: Font(size: theme.headingFont(level).pointSize, bold: true))

    case .blockquote, .callout:
      var c = ctx
      var barColor = theme.quoteBar
      if case .callout(let t) = b.kind { barColor = theme.calloutColor(t) }
      c.bars.append((x: ctx.indent + 2, color: barColor))
      c.indent = ctx.indent + 18 * theme.zoom
      c.quoteDepth += 1
      if case .callout = b.kind {} else { c.textColor = theme.secondary }
      applyCtx(abs, c)
      for m in b.markers { hide(m.shifted(by: offset)) }
      if case .callout(let t) = b.kind, let title = b.content?.shifted(by: offset) {
        if revealed(title) {
          dim(title)
        } else {
          hide(title)
          let f = theme.font(bold: true, italic: false)
          let icon: String =
            ["NOTE": "ⓘ", "TIP": "💡", "IMPORTANT": "❗", "WARNING": "⚠️", "CAUTION": "⛔"][t.rawValue]
            ?? "ⓘ"
          let d = InlineDecoration(.text("\(icon) \(t.title)", f, barColor, raise: 0))
          add(NSRange(location: title.location, length: 1), [.mdInline: d])
          add(NSRange(location: title.end - 1, length: 1), [.kern: d.width])
          // The title line is all hidden source; keep it a full line tall.
          spec(title.location) { s in s.minHeight = f.ascender - f.descender + f.leading + 2 }
        }
      }
      for (i, child) in b.children.enumerated() {
        styleBlock(child, offset: offset, ctx: c, siblingIndex: i, siblings: b.children)
      }

    case .list:
      for (i, child) in b.children.enumerated() {
        styleBlock(child, offset: offset, ctx: ctx, siblingIndex: i, siblings: b.children)
      }

    case .listItem(let ordered, let task):
      styleListItem(
        b, offset: offset, ctx: ctx, ordered: ordered, task: task, index: siblingIndex,
        siblings: siblings)

    case .code(let language):
      styleCode(b, offset: offset, ctx: ctx, language: language, revealed: blockRevealed)

    case .math:
      let raw = b.content.map { text.substring(with: $0.shifted(by: offset)) } ?? ""
      let latex = MathPreprocessor.prepare(
        raw, context: mathContext, physics: preferences.physicsPackage)
      let prepared = MathPreprocessor.prepare(
        latex, context: mathContext, physics: preferences.physicsPackage)
      let req = RenderRequest.math(
        latex: prepared, display: true, dark: theme.isDark, fontSize: theme.body.pointSize * 1.15,
        number: mathContext.numbers[abs.location])
      styleRenderedBlock(b, offset: offset, ctx: ctx, request: req, revealed: blockRevealed)

    case .diagram(let kind):
      let src = b.content.map { text.substring(with: $0.shifted(by: offset)) } ?? ""
      styleRenderedBlock(
        b, offset: offset, ctx: ctx, request: .diagram(kind, source: src, dark: theme.isDark),
        revealed: blockRevealed, debounce: true)

    case .html:
      let src = text.substring(with: abs)
      if let tag = ImageTag.parse(src),
        renderBlockImage(
          Inline(kind: .image(source: tag.src, alt: tag.alt), range: b.range, size: tag.size),
          block: abs, ctx: ctx)
      {
        return
      }
      if let media = MediaEmbed.parse(src) {
        styleMedia(media, block: abs, ctx: ctx, revealed: blockRevealed)
      } else {
        styleRenderedBlock(
          b, offset: offset, ctx: ctx,
          request: .html(src, width: contentWidth(ctx), dark: theme.isDark), revealed: blockRevealed
        )
      }

    case .table:
      styleTable(b, offset: offset, ctx: ctx)

    case .thematicBreak:
      applyCtx(abs, ctx)
      if blockRevealed {
        dim(abs)
      } else {
        let marker = b.markers.first?.shifted(by: offset) ?? abs
        hideLines(marker)
        spec(marker.location) { s in s.after = 24 * theme.zoom }
        deco(marker.location).rule = theme.hr
      }

    case .pageBreak:
      applyCtx(abs, ctx)
      if blockRevealed {
        dim(abs)
        add(abs, [.font: theme.mono])
      } else {
        hideLines(b.markers.first?.shifted(by: offset) ?? abs)
        spec(abs.location) { s in s.after = 28 * theme.zoom }
        let d = deco(abs.location)
        d.rule = theme.secondary
        d.ruleDashed = true
        d.ruleLabel = "Page Break"
      }

    case .frontMatter:
      styleSourceBox(abs, ctx: ctx, color: theme.secondary)
      if let error = FrontMatter.parse(text.substring(with: abs)).error {
        add(
          abs,
          [
            .underlineStyle: NSUnderlineStyle.patternDot.union(.single).rawValue,
            .underlineColor: NSColor.systemRed, .toolTip: error,
          ])
      }

    case .comment, .linkReferenceDefinition:
      if blockRevealed || b.kind == .linkReferenceDefinition && mode == .source {
        applyCtx(abs, ctx)
        add(abs, [.font: theme.mono, .foregroundColor: theme.secondary])
      } else {
        hideLines(b.markers.first?.shifted(by: offset) ?? abs)
      }

    case .toc:
      styleTOC(b, offset: offset, ctx: ctx, revealed: blockRevealed)

    case .footnoteDefinition(let id):
      applyCtx(abs, ctx)
      let small = theme.font(size: theme.body.pointSize * 0.88, bold: false, italic: false)
      add(abs, [.font: small, .foregroundColor: theme.secondary])
      if let m = b.markers.first?.shifted(by: offset) {
        if revealed(m) {
          dim(m)
        } else {
          hide(m)
          let n = model.footnoteNumbers[id].map(String.init) ?? id
          let d = InlineDecoration(.text("[\(n)]", small, theme.link, raise: 0))
          add(NSRange(location: m.location, length: 1), [.mdInline: d, .mdLink: "#fnref:\(id)"])
          add(NSRange(location: m.end - 1, length: 1), [.kern: d.width + 6])
        }
      }
      styleInlines(b.inlines, offset: offset, font: Font(size: small.pointSize))
    }
  }

  private func contentWidth(_ ctx: Ctx) -> CGFloat { max(100, containerWidth - ctx.indent - 10) }

  // MARK: Lists

  private func styleListItem(
    _ b: Block, offset: Int, ctx: Ctx, ordered: Bool, task: Bool?, index: Int, siblings: [Block]
  ) {
    let abs = b.range.shifted(by: offset)
    let unit = 1.7 * theme.body.pointSize
    var c = ctx
    c.indent = ctx.indent + unit
    c.listDepth += 1
    c.inList = true
    applyCtx(abs, c)
    // Leading indentation on every line is presentation; the indent comes from the style.
    forEachLine(abs) { line in
      var n = 0
      while line.location + n < line.end, line.location + n < abs.end {
        let ch = text.character(at: line.location + n)
        if ch == 0x20 || ch == 0x09 { n += 1 } else { break }
      }
      if n > 0 { hide(NSRange(location: line.location, length: n)) }
    }
    if let m = b.listMarker?.shifted(by: offset) {
      hide(m)
    }
    // Task items show only the box, as in Typora.
    if let m = b.listMarker?.shifted(by: offset), task == nil {
      let label: String
      if ordered {
        let start =
          siblings.first?.info.flatMap {
            Int($0.trimmingCharacters(in: CharacterSet(charactersIn: ".)")))
          } ?? 1
        label = "\(start + index)."
      } else {
        label = ["•", "◦", "▪"][ctx.listDepth % 3]
      }
      let f =
        ordered
        ? theme.body : theme.font(size: theme.body.pointSize * 1.1, bold: false, italic: false)
      let w = (label as NSString).size(withAttributes: [.font: f]).width
      let d = InlineDecoration(
        .text(label, f, ctx.textColor ?? theme.text, raise: 0), dx: -(w + 0.35 * unit))
      add(NSRange(location: m.location, length: 1), [.mdInline: d])
    }
    if let t = b.taskMarker?.shifted(by: offset) {
      var r = t
      if r.end < text.length, text.character(at: r.end) == 0x20 { r.length += 1 }
      hide(r)
      let d = InlineDecoration(.checkbox(checked: task == true, color: theme.link))
      add(NSRange(location: r.location, length: 1), [.mdInline: d, .mdTask: NSValue(range: t)])
      add(NSRange(location: r.end - 1, length: 1), [.kern: 24 * theme.zoom])
    }
    for (i, child) in b.children.enumerated() {
      styleBlock(child, offset: offset, ctx: c, siblingIndex: i, siblings: b.children)
    }
  }

  // MARK: Code & rendered blocks

  private func styleSourceBox(_ abs: NSRange, ctx: Ctx, color: NSColor? = nil) {
    applyCtx(abs, ctx)
    add(abs, [.font: theme.mono, .foregroundColor: color ?? theme.codeText])
    var lines: [NSRange] = []
    forEachLine(trimTrailingNewline(abs)) { lines.append($0) }
    for (i, line) in lines.enumerated() {
      let d = deco(line.location)
      d.background = theme.codeBackground
      d.inset = ctx.indent
      d.roundTop = i == 0
      d.roundBottom = i == lines.count - 1
      spec(line.location) { s in
        s.first = ctx.indent + 12
        s.head = ctx.indent + 12
        s.lineSpacing = 2 * theme.zoom
        s.before = i == 0 ? 8 * theme.zoom : 0
        s.after = i == lines.count - 1 ? 14 * theme.zoom : 0
      }
    }
  }

  private func styleCode(_ b: Block, offset: Int, ctx: Ctx, language: String?, revealed: Bool) {
    let abs = b.range.shifted(by: offset)
    let content = b.content?.shifted(by: offset)
    if revealed || b.markers.isEmpty {
      styleSourceBox(trimTrailingNewline(abs), ctx: ctx)
      for m in b.markers { dim(m.shifted(by: offset)) }
    } else {
      for m in b.markers { hideLines(m.shifted(by: offset)) }
      if let content, content.length > 0 {
        styleSourceBox(trimTrailingNewline(content), ctx: ctx)
      } else {
        // Empty block: keep one visible box line from the opening fence.
        styleSourceBox(trimTrailingNewline(abs), ctx: ctx)
        for m in b.markers { dim(m.shifted(by: offset)) }
      }
    }
    guard let content, content.length > 0 else { return }
    let body = trimTrailingNewline(content)
    // Fenced blocks get a clickable language label; empty while the caret is elsewhere.
    if !b.markers.isEmpty, (language?.isEmpty == false) || revealed {
      let d = deco(lineStart(body.location))
      d.label = language?.isEmpty == false ? language : "language"
      d.labelColor = theme.secondary
    }
    if preferences.codeLineNumbers {
      var n = 1
      forEachLine(body) { line in
        let d = deco(line.location)
        d.lineNumber = n
        d.gutterFont = theme.font(
          size: theme.mono.pointSize * 0.85, bold: false, italic: false, mono: true)
        n += 1
      }
      specLines(body) { s in
        s.first += 28 * theme.zoom
        s.head += 28 * theme.zoom
      }
    }
    if let highlighter, let language {
      for (r, color) in highlighter.highlight(
        text.substring(with: body), language: language, colors: theme.tokenColors)
      {
        add(r.shifted(by: body.location), [.foregroundColor: color])
      }
    }
  }

  private func trimTrailingNewline(_ r: NSRange) -> NSRange {
    var len = r.length
    while len > 0, r.location + len - 1 < text.length {
      let ch = text.character(at: r.location + len - 1)
      if ch == 0x0A || ch == 0x0D { len -= 1 } else { break }
    }
    return NSRange(location: r.location, length: len)
  }

  /// Math, diagrams, HTML: the render replaces the source; with the caret inside, the source
  /// shows as a box with the render as a live preview below it.
  private func styleRenderedBlock(
    _ b: Block, offset: Int, ctx: Ctx, request: RenderRequest, revealed: Bool,
    debounce: Bool = false
  ) {
    let abs = trimTrailingNewline(b.range.shifted(by: offset))
    let cached =
      debounce && revealed
      ? renders.result(for: request, debounceKey: abs.location) : renders.result(for: request)
    guard let result = cached else {
      // Not rendered yet: show the source until it is.
      styleSourceBox(abs, ctx: ctx)
      return
    }
    // A failed render keeps the source on screen, with the error under it.
    if revealed || result.image == nil {
      styleSourceBox(abs, ctx: ctx)
    } else {
      hideLines(abs)
      applyCtxBarsOnly(abs, ctx)
    }
    placeRender(result, after: abs, ctx: ctx, gap: revealed ? 6 : 10)
  }

  private func applyCtxBarsOnly(_ r: NSRange, _ ctx: Ctx) {
    if !ctx.bars.isEmpty { forEachLine(r) { line in deco(line.location).bars = ctx.bars } }
  }

  private func placeRender(
    _ result: RenderResult, after r: NSRange, ctx: Ctx, gap: CGFloat, centered: Bool = true
  ) {
    var lastLine = r.location
    forEachLine(r) { lastLine = $0.location }
    let d = deco(lastLine)
    var size = result.size
    let maxW = contentWidth(ctx)
    if size.width > maxW, size.width > 0 {
      size = CGSize(width: maxW, height: size.height * maxW / size.width)
    }
    d.render = result.image
    d.renderSize = size
    d.renderCentered = centered
    d.renderError = result.error
    d.inset = ctx.indent
    let h = result.error != nil && result.image == nil ? 22 : size.height
    spec(lastLine) { s in
      s.first = max(s.first, ctx.indent)
      s.head = max(s.head, ctx.indent)
      s.after = h + gap * 2 * theme.zoom
    }
  }

  private func soleImage(_ b: Block, offset: Int) -> Inline? {
    guard b.inlines.count == 1, case .image = b.inlines[0].kind else { return nil }
    let i = b.inlines[0]
    let t = text.substring(with: b.range.shifted(by: offset)).trimmingCharacters(
      in: .whitespacesAndNewlines)
    return t.utf16.count == i.range.length ? i : nil
  }

  private func renderBlockImage(_ img: Inline, block: NSRange, ctx: Ctx) -> Bool {
    guard case .image(let src, _) = img.kind, let url = resolveURL(src) else { return false }
    let abs = trimTrailingNewline(block)
    guard var result = renders.result(for: .image(url)) else { return false }
    result.size = ImageTag.apply(img.size, natural: result.size, width: contentWidth(ctx))
    applyCtx(abs, ctx)
    // A missing image keeps its source visible, with the path under it.
    if revealed(abs) || result.image == nil {
      add(abs, [.foregroundColor: theme.secondary])
    } else {
      hideLines(abs)
    }
    placeRender(result, after: abs, ctx: ctx, gap: 6)
    return true
  }

  func resolveURL(_ src: String) -> URL? {
    let s = src.trimmingCharacters(in: .whitespaces)
    guard !s.isEmpty else { return nil }
    if let u = URL(string: s), let scheme = u.scheme,
      ["http", "https", "file", "data"].contains(scheme.lowercased())
    {
      return u
    }
    let decoded = s.removingPercentEncoding ?? s
    if decoded.hasPrefix("/") {
      if let root = frontMatterValue("typora-root-url") {
        let base = URL(fileURLWithPath: root, relativeTo: documentURL?.deletingLastPathComponent())
        return base.appendingPathComponent(String(decoded.dropFirst())).standardizedFileURL
      }
      return URL(fileURLWithPath: decoded)
    }
    if decoded.hasPrefix("~") {
      return URL(fileURLWithPath: (decoded as NSString).expandingTildeInPath)
    }
    guard let dir = documentURL?.deletingLastPathComponent() else { return nil }
    return URL(fileURLWithPath: decoded, relativeTo: dir).standardizedFileURL
  }

  func frontMatterValue(_ key: String) -> String? {
    guard let fm = model.frontMatter else { return nil }
    return FrontMatter.value(key, in: FrontMatter.parse(fm).values)
  }

  // MARK: Tables, TOC, media (rendered as drawn blocks; editing lives in overlays)

  private func styleTable(_ b: Block, offset: Int, ctx: Ctx) {
    let abs = trimTrailingNewline(b.range.shifted(by: offset))
    guard let table = TableModel(source: text.substring(with: abs)) else {
      styleSourceBox(abs, ctx: ctx)
      return
    }
    let size = TableLayout.size(table, theme: theme, width: contentWidth(ctx))
    hideLines(abs)
    applyCtxBarsOnly(abs, ctx)
    // Table space sits before the first (hidden) line; the overlay grid is placed there.
    spec(abs.location) { s in
      s.first = ctx.indent
      s.head = ctx.indent
      s.before = size.height + Self.tableGap * 2
    }
  }

  static let tableGap: CGFloat = 8

  private func styleTOC(_ b: Block, offset: Int, ctx: Ctx, revealed: Bool) {
    let abs = trimTrailingNewline(b.range.shifted(by: offset))
    if revealed {
      applyCtx(abs, ctx)
      dim(abs)
    } else {
      hideLines(abs)
    }
    let image = TOCRenderer.image(model.headings, theme: theme, width: contentWidth(ctx))
    placeRender(
      RenderResult(image: image.image, size: image.size), after: abs, ctx: ctx, gap: 6,
      centered: false)
  }

  private func styleMedia(_ media: MediaEmbed, block: NSRange, ctx: Ctx, revealed: Bool) {
    let abs = trimTrailingNewline(block)
    if revealed {
      styleSourceBox(abs, ctx: ctx)
    } else {
      hideLines(abs)
    }
    let size = Self.mediaSize(media, width: contentWidth(ctx))
    placeRender(RenderResult(image: nil, size: size), after: abs, ctx: ctx, gap: 6)
  }

  static func mediaSize(_ media: MediaEmbed, width: CGFloat) -> CGSize {
    let w = min(width, media.width ?? 560)
    return CGSize(width: w, height: media.kind == .audio ? 40 : media.height ?? w * 9 / 16)
  }

  // MARK: Inlines

  struct Font {
    var size: CGFloat?
    var bold = false
    var italic = false
  }

  private func styleInlines(_ list: [Inline], offset: Int, font: Font) {
    for i in list { styleInline(i, offset: offset, font: font) }
  }

  private func hideMarkers(_ i: Inline, offset: Int, reveal: Bool) {
    for m in i.markers {
      let r = m.shifted(by: offset)
      if reveal { dim(r) } else { hide(r) }
    }
  }

  private func styleInline(_ i: Inline, offset: Int, font: Font) {
    let r = i.range.shifted(by: offset)
    let rev = revealed(r)
    var f = font
    switch i.kind {
    case .emphasis, .strong:
      if i.kind == .emphasis { f.italic = true } else { f.bold = true }
      add(r, [.font: theme.font(size: f.size, bold: f.bold, italic: f.italic)])
      hideMarkers(i, offset: offset, reveal: rev)
    case .strikethrough:
      add(r, [.strikethroughStyle: NSUnderlineStyle.single.rawValue])
      hideMarkers(i, offset: offset, reveal: rev)
    case .code:
      add(
        r,
        [
          .font: theme.font(
            size: (f.size ?? theme.body.pointSize) * 0.88, bold: false, italic: false, mono: true),
          .backgroundColor: theme.codeBackground, .foregroundColor: theme.codeText,
        ])
      hideMarkers(i, offset: offset, reveal: rev)
      return
    case .highlight:
      add(r, [.backgroundColor: theme.highlight])
      hideMarkers(i, offset: offset, reveal: rev)
    case .superscript, .subscript:
      let size = (f.size ?? theme.body.pointSize) * 0.72
      let raise = i.kind == .superscript ? size * 0.5 : -size * 0.25
      add(
        r, [.font: theme.font(size: size, bold: f.bold, italic: f.italic), .baselineOffset: raise])
      hideMarkers(i, offset: offset, reveal: rev)
    case .link(let dest):
      guard let resolved = resolveLink(dest) else {
        styleInlines(i.children, offset: offset, font: f)
        return
      }
      add(r, [.foregroundColor: theme.link, .mdLink: resolved, .cursor: NSCursor.pointingHand])
      hideMarkers(i, offset: offset, reveal: rev)
    case .autolink(let url):
      add(r, [.foregroundColor: theme.link, .mdLink: url])
      hideMarkers(i, offset: offset, reveal: rev)
    case .image(let src, let alt):
      _ = alt
      styleInlineImage(i, r, src: src, reveal: rev)
      return
    case .math(let latex):
      let req = RenderRequest.math(
        latex: latex, display: false, dark: theme.isDark, fontSize: f.size ?? theme.body.pointSize,
        number: nil)
      if !rev, let res = renders.result(for: req), let img = res.image {
        substitute(r, with: InlineDecoration(.image(img, size: res.size, baseline: res.descent)))
        spec(r.location) { s in s.minHeight = max(s.minHeight, res.size.height + 4) }
      } else {
        add(
          r,
          [
            .font: theme.font(
              size: (f.size ?? theme.body.pointSize) * 0.88, bold: false, italic: false, mono: true),
            .foregroundColor: rev ? theme.text : theme.secondary,
          ])
        if let res = renders.result(for: req), res.error != nil {
          add(
            r,
            [
              .underlineStyle: NSUnderlineStyle.patternDot.union(.single).rawValue,
              .underlineColor: NSColor.systemRed,
            ])
        }
      }
      return
    case .emoji(let e):
      if rev {
        dim(r)
      } else {
        substitute(
          r,
          with: InlineDecoration(
            .text(e, theme.font(size: f.size, bold: false, italic: false), theme.text, raise: 0)))
      }
      return
    case .footnoteRef(let id):
      guard model.footnoteDefinitions[id] != nil else { return }
      if rev {
        dim(r)
      } else {
        let n = model.footnoteNumbers[id].map(String.init) ?? id
        let small = theme.font(size: theme.body.pointSize * 0.7, bold: false, italic: false)
        substitute(
          r, with: InlineDecoration(.text(n, small, theme.link, raise: theme.body.pointSize * 0.35))
        )
        add(r, [.mdLink: "#fn:\(id)", .toolTip: footnoteText(id)])
      }
      return
    case .entity(let ch):
      if rev {
        dim(r)
      } else {
        substitute(
          r,
          with: InlineDecoration(
            .text(
              ch, theme.font(size: f.size, bold: f.bold, italic: f.italic), theme.text, raise: 0)))
      }
      return
    case .escape:
      hideMarkers(i, offset: offset, reveal: rev)
    case .html(let style):
      let inner =
        i.markers.count == 2
        ? NSRange(location: i.markers[0].end, length: i.markers[1].location - i.markers[0].end)
          .shifted(by: offset) : r
      var a: [NSAttributedString.Key: Any] = [:]
      if style.underline { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
      if style.bold || style.italic || style.fontScale != nil {
        f.bold = f.bold || style.bold
        f.italic = f.italic || style.italic
        if let s = style.fontScale { f.size = (f.size ?? theme.body.pointSize) * s }
        a[.font] = theme.font(size: f.size, bold: f.bold, italic: f.italic)
      }
      if let c = style.color { a[.foregroundColor] = NSColor(hex: c) }
      if let c = style.background { a[.backgroundColor] = NSColor(hex: c) }
      if style.mark { a[.backgroundColor] = theme.highlight }
      if style.kbd {
        a[.font] = theme.font(
          size: (f.size ?? theme.body.pointSize) * 0.85, bold: false, italic: false)
        a[.backgroundColor] = theme.codeBackground
      }
      if style.superscript || style.subscript {
        let size = (f.size ?? theme.body.pointSize) * 0.72
        a[.font] = theme.font(size: size, bold: f.bold, italic: f.italic)
        a[.baselineOffset] = style.superscript ? size * 0.5 : -size * 0.25
      }
      if !a.isEmpty { add(inner, a) }
      hideMarkers(i, offset: offset, reveal: rev)
    case .comment:
      if rev { add(r, [.foregroundColor: theme.secondary]) } else { hide(r) }
      return
    }
    styleInlines(i.children, offset: offset, font: f)
  }

  /// Hide `r` and draw `d` in its place, reserving the decoration's width.
  private func substitute(_ r: NSRange, with d: InlineDecoration) {
    hide(r)
    add(NSRange(location: r.location, length: 1), [.mdInline: d])
    add(NSRange(location: r.end - 1, length: 1), [.kern: d.width])
  }

  private func styleInlineImage(_ i: Inline, _ r: NSRange, src: String, reveal: Bool) {
    guard let url = resolveURL(src), let res = renders.result(for: .image(url)),
      let img = res.image, !reveal
    else {
      add(r, [.foregroundColor: theme.secondary])
      return
    }
    var size = ImageTag.apply(i.size, natural: res.size, width: containerWidth - 20)
    let maxH = theme.body.pointSize * 6
    if i.size == nil, size.height > maxH {
      size = CGSize(width: size.width * maxH / size.height, height: maxH)
    }
    substitute(r, with: InlineDecoration(.image(img, size: size, baseline: 0)))
    spec(r.location) { s in s.minHeight = max(s.minHeight, size.height + 4) }
  }

  func resolveLink(_ dest: String) -> String? {
    if dest.hasPrefix("ref:") { return model.linkRefs[String(dest.dropFirst(4))] }
    return dest
  }

  private func footnoteText(_ id: String) -> String {
    guard let r = model.footnoteDefinitions[id], r.end <= text.length else { return "" }
    let s = text.substring(with: r)
    return s.replacingOccurrences(of: #"^\[\^[^\]]+\]:\s*"#, with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: Source mode

  private func styleSource(_ e: BlockEntry, index: Int) {
    func go(_ b: Block) {
      let abs = b.range.shifted(by: e.start)
      switch b.kind {
      case .heading, .setextHeading:
        add(
          abs,
          [
            .foregroundColor: theme.heading,
            .font: theme.font(bold: true, italic: false, mono: true),
          ])
      case .code, .diagram, .math, .frontMatter, .html, .table:
        add(abs, [.foregroundColor: theme.codeText])
      case .comment, .linkReferenceDefinition:
        add(abs, [.foregroundColor: theme.secondary])
      default: break
      }
      for m in b.markers { add(m.shifted(by: e.start), [.foregroundColor: theme.secondary]) }
      if let m = b.listMarker { add(m.shifted(by: e.start), [.foregroundColor: theme.link]) }
      forEachInline(Block(kind: .paragraph, range: b.range, inlines: b.inlines)) { i in
        for m in i.markers { add(m.shifted(by: e.start), [.foregroundColor: theme.secondary]) }
        if case .link = i.kind { add(i.range.shifted(by: e.start), [.foregroundColor: theme.link]) }
      }
      b.children.forEach(go)
    }
    go(e.block)
  }
}
