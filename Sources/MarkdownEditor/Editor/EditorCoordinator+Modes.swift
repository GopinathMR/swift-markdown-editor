import AppKit

extension EditorCoordinator {
  func selectionDidChangeHooks() {
    updateSubstitutionContext()
    if controller?.isFocusMode == true { applyFocus() }
    if controller?.isTypewriterMode == true {
      let fromClick =
        NSApp.currentEvent.map {
          [.leftMouseDown, .leftMouseUp, .leftMouseDragged].contains($0.type)
        } ?? false
      if !fromClick || preferences.typewriterCentersOnClick { centerCaret() }
    }
  }

  // MARK: Focus mode

  func focusModeChanged() {
    if controller?.isFocusMode == true { applyFocus() } else { clearFocus() }
  }

  /// Dim everything but the caret's top-level block. Rendering attributes only: the
  /// storage (and undo) never see it.
  func applyFocus() {
    guard let lm = textView.textLayoutManager, let cs = lm.textContentManager else { return }
    clearFocus()
    let caret = textView.selectedRange().location
    let block =
      model.entry(at: min(caret, max(0, text.length - 1)))?.range
      ?? NSRange(location: 0, length: text.length)
    let dim = styler.theme.text.withAlphaComponent(0.28)
    for r in [
      NSRange(location: 0, length: block.location),
      NSRange(location: block.end, length: text.length - block.end),
    ] where r.length > 0 {
      guard let s = cs.location(cs.documentRange.location, offsetBy: r.location),
        let e = cs.location(s, offsetBy: r.length),
        let tr = NSTextRange(location: s, end: e)
      else { continue }
      lm.addRenderingAttribute(.foregroundColor, value: dim, for: tr)
    }
  }

  func clearFocus() {
    guard let lm = textView.textLayoutManager else { return }
    lm.removeRenderingAttribute(.foregroundColor, for: lm.documentRange)
  }

  // MARK: Typewriter mode

  func typewriterModeChanged() {
    let on = controller?.isTypewriterMode == true
    scrollView.automaticallyAdjustsContentInsets = !on
    let half = on ? scrollView.contentView.bounds.height / 2 : 0
    scrollView.contentInsets = NSEdgeInsets(top: half, left: 0, bottom: half, right: 0)
    if on { centerCaret() }
  }

  /// Keep the caret line in the vertical middle of the viewport.
  func centerCaret() {
    let r = rectInView(for: NSRange(location: textView.selectedRange().location, length: 0))
    guard r != .zero else { return }
    let visible = scrollView.contentView.bounds
    let y = r.midY - visible.height / 2
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }

  // MARK: Clipboard

  private var selectionMarkdown: String { text.substring(with: textView.selectedRange()) }

  func htmlFragment(_ markdown: String) -> String {
    let parser = MarkdownParser(preferences: preferences)
    let m = parser.parse(markdown as NSString).model
    let r = HTMLRenderer(
      text: markdown as NSString, model: m, preferences: preferences,
      render: { [renders] in renders.cached($0) },
      resolveURL: { [styler] in styler.resolveURL($0) },
      embedImages: true, dark: false)
    return r.body(fontSize: styler.theme.body.pointSize)
  }

  /// ⌘C in rendered mode: HTML and RTF for rich apps, markdown source as plain text.
  func handleCopy() -> Bool {
    guard mode == .rendered, textView.selectedRange().length > 0 else { return false }
    let md = selectionMarkdown
    let html = htmlFragment(md)
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.declareTypes([.html, .rtf, .string], owner: nil)
    pb.setString(md, forType: .string)
    pb.setString(html, forType: .html)
    if let attr = try? NSAttributedString(
      data: Data(("<meta charset=\"utf-8\">" + html).utf8),
      options: [.documentType: NSAttributedString.DocumentType.html],
      documentAttributes: nil),
      let rtf = try? attr.data(
        from: NSRange(location: 0, length: attr.length),
        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    {
      pb.setData(rtf, forType: .rtf)
    }
    return true
  }

  func copyAsMarkdown() {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(selectionMarkdown, forType: .string)
  }

  func copyAsHTML() {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(htmlFragment(selectionMarkdown), forType: .string)
  }

  /// ⌘V: images, a URL over a selection, HTML/RTF converted to markdown; else plain text.
  func handlePaste(plain: Bool) -> Bool {
    let pb = NSPasteboard.general
    let sel = textView.selectedRange()
    if plain || mode == .source {
      guard let s = pb.string(forType: .string) else { return false }
      return replace(
        sel, with: s,
        selectAfter: NSRange(location: sel.location + (s as NSString).length, length: 0))
    }
    if pasteImagesIfPresent(pb) { return true }
    if sel.length > 0,
      let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
      !s.contains(" "), !s.contains("\n"), let url = URL(string: s), let scheme = url.scheme,
      ["http", "https", "mailto"].contains(scheme)
    {
      let label = text.substring(with: sel)
      let link = "[\(label)](\(s))"
      return replace(
        sel, with: link,
        selectAfter: NSRange(location: sel.location + (link as NSString).length, length: 0))
    }
    var markdown: String?
    if let html = pb.string(forType: .html) {
      markdown = HTMLToMarkdown.convert(html)
    } else if let rtf = pb.data(forType: .rtf),
      let attr = NSAttributedString(rtf: rtf, documentAttributes: nil),
      let data = try? attr.data(
        from: NSRange(location: 0, length: attr.length),
        documentAttributes: [.documentType: NSAttributedString.DocumentType.html]),
      let html = String(data: data, encoding: .utf8)
    {
      markdown = HTMLToMarkdown.convert(html)
    }
    guard var md = markdown, !md.isEmpty else { return false }
    if eol != "\n" { md = md.replacingOccurrences(of: "\n", with: eol) }
    return replace(
      sel, with: md,
      selectAfter: NSRange(location: sel.location + (md as NSString).length, length: 0))
  }
}
