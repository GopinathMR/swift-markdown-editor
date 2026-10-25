import AppKit

extension EditorCoordinator {
  // MARK: Clicks

  /// Checkbox toggles, ⌘-click links, TOC rows. Returns true when the click was consumed.
  func handleClick(at point: CGPoint, command: Bool) -> Bool {
    guard mode == .rendered else { return false }
    if handleCodeLabelClick(at: point) { return true }
    let idx = textView.characterIndexForInsertion(at: point)
    // Task boxes: the box is drawn over the hidden `[ ]`, so test geometry, not the index.
    for i in max(0, idx - 5)...min(storage.length, idx + 1) where i < storage.length {
      guard let v = storage.attribute(.mdTask, at: i, effectiveRange: nil) as? NSValue else {
        continue
      }
      let r = v.rangeValue
      let rect = rectInView(for: NSRange(location: r.location, length: 1))
      if point.x >= rect.minX - 2, point.x <= rect.minX + 22, point.y >= rect.minY - 4,
        point.y <= rect.maxY + 4
      {
        toggleTask(r)
        return true
      }
    }
    if let (rows, origin) = tocRows(near: point) {
      for (rowRect, slug) in rows where rowRect.offsetBy(dx: origin.x, dy: origin.y).contains(point)
      {
        reveal(slug: slug)
        return true
      }
    }
    guard command, idx <= storage.length else { return false }
    for i in [idx, idx - 1] where i >= 0 && i < storage.length {
      if let dest = storage.attribute(.mdLink, at: i, effectiveRange: nil) as? String {
        openLink(dest)
        return true
      }
    }
    return false
  }

  func rectInView(for range: NSRange) -> CGRect {
    var actual = NSRange()
    let screen = textView.firstRect(forCharacterRange: range, actualRange: &actual)
    guard let window = textView.window else { return .zero }
    let windowRect = window.convertFromScreen(screen)
    return textView.convert(windowRect, from: nil)
  }

  private func toggleTask(_ r: NSRange) {
    guard r.length == 3 else { return }
    let mid = NSRange(location: r.location + 1, length: 1)
    let checked = text.substring(with: mid).lowercased() == "x"
    let sel = textView.selectedRange()
    replace(mid, with: checked ? " " : "x", selectAfter: sel)
  }

  // MARK: Links

  func openLink(_ dest: String) {
    if dest.hasPrefix("#fnref:") {
      let id = String(dest.dropFirst(7))
      if let i = firstFootnoteRef(id) { jump(to: i) }
      return
    }
    if dest.hasPrefix("#fn:") {
      if let r = model.footnoteDefinitions[String(dest.dropFirst(4))] { jump(to: r.location) }
      return
    }
    if dest.hasPrefix("#") {
      reveal(
        slug: (dest.dropFirst().removingPercentEncoding ?? String(dest.dropFirst())).lowercased())
      return
    }
    if let url = URL(string: dest), let scheme = url.scheme?.lowercased(),
      ["http", "https", "mailto", "ftp"].contains(scheme)
    {
      hooks.openLink(.web(url))
      return
    }
    // Local file, optionally `file.md#heading`; `.md` may be omitted.
    var path = dest
    var heading: String?
    if let hash = path.firstIndex(of: "#") {
      heading = String(path[path.index(after: hash)...])
      path = String(path[..<hash])
    }
    path = path.removingPercentEncoding ?? path
    let base =
      documentURL?.deletingLastPathComponent()
      ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    var url =
      path.hasPrefix("/")
      ? URL(fileURLWithPath: path)
      : URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
    if url.pathExtension.isEmpty, FileManager.default.fileExists(atPath: url.path + ".md") {
      url = url.appendingPathExtension("md")
    }
    hooks.openLink(
      .file(url, heading: heading, exists: FileManager.default.fileExists(atPath: url.path)))
  }

  private func firstFootnoteRef(_ id: String) -> Int? {
    for e in model.entries {
      var found: Int?
      forEachInline(e.block) { i in
        if found == nil, case .footnoteRef(let fid) = i.kind, fid == id {
          found = i.range.location + e.start
        }
      }
      if let found { return found }
    }
    return nil
  }

  func reveal(slug: String) {
    guard let h = model.headings.first(where: { $0.slug == slug }) else { return }
    jump(to: h.range.location + (h.range.length > 0 ? 0 : 0))
  }

  func jump(to location: Int) {
    let loc = min(location, storage.length)
    textView.window?.makeFirstResponder(textView)
    textView.setSelectedRange(NSRange(location: loc, length: 0))
    scrollToTop(loc)
  }

  /// Scroll so `location` sits near the top of the viewport (outline / TOC jumps).
  func scrollToTop(_ location: Int) {
    guard let lm = textView.textLayoutManager, let cs = lm.textContentManager else { return }
    guard let loc = cs.location(cs.documentRange.location, offsetBy: location) else { return }
    lm.ensureLayout(
      for: NSTextRange(location: cs.documentRange.location, end: loc) ?? cs.documentRange)
    if let f = lm.textLayoutFragment(for: loc) {
      let y = f.layoutFragmentFrame.minY + textView.textContainerOrigin.y - 12
      scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
      scrollView.reflectScrolledClipView(scrollView.contentView)
      lm.textViewportLayoutController.layoutViewport()
    }
  }

  private func tocRows(near point: CGPoint) -> ([(CGRect, String)], CGPoint)? {
    let width = (textView.textContainer?.size.width ?? 600) - 10
    for (b, off) in model.blocks(where: { $0 == .toc }) {
      let range = b.range.shifted(by: off)
      let rows = TOCRenderer.image(model.headings, theme: styler.theme, width: width).rows
      let rect = rectInView(for: NSRange(location: range.location, length: 0))

      // The TOC render is drawn after the (hidden) `[toc]` line, inset like body text.
      let origin = CGPoint(
        x: textView.textContainerOrigin.x + (textView.textContainer?.lineFragmentPadding ?? 5),
        y: rect.maxY + 6)
      if point.y >= origin.y - 4, point.y <= origin.y + (rows.last?.0.maxY ?? 0) + 4 {
        return (rows, origin)
      }
    }
    return nil
  }
}

extension EditorCoordinator {
  /// Run `change` (a restyle that resizes blocks, e.g. a finished render) without the
  /// visible text jumping: the first visible line stays where it was on screen.
  func keepingViewport(_ change: () -> Void) {
    guard let lm = textView.textLayoutManager, let cs = lm.textContentManager,
      let viewport = lm.textViewportLayoutController.viewportRange
    else { return change() }
    let visibleTop = scrollView.contentView.bounds.minY
    let anchor = cs.offset(from: cs.documentRange.location, to: viewport.location)
    let before = lm.textLayoutFragment(for: viewport.location)?.layoutFragmentFrame.minY
    change()
    guard let before, let loc = cs.location(cs.documentRange.location, offsetBy: anchor) else {
      return
    }
    lm.ensureLayout(
      for: NSTextRange(location: cs.documentRange.location, end: loc) ?? cs.documentRange)
    guard let after = lm.textLayoutFragment(for: loc)?.layoutFragmentFrame.minY, after != before
    else { return }
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, visibleTop + after - before)))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    lm.textViewportLayoutController.layoutViewport()
  }
}

extension EditorCoordinator {
  /// Scroll `location` into view a third of the way down, using exact layout.
  /// (`scrollRangeToVisible` goes by TextKit 2's height estimates and can land far off.)
  func reveal(location: Int) {
    guard let lm = textView.textLayoutManager, let cs = lm.textContentManager,
      let loc = cs.location(cs.documentRange.location, offsetBy: min(location, text.length))
    else { return }
    lm.ensureLayout(
      for: NSTextRange(location: cs.documentRange.location, end: loc) ?? cs.documentRange)
    guard let f = lm.textLayoutFragment(for: loc) else { return }
    let visible = scrollView.contentView.bounds
    let y = f.layoutFragmentFrame.minY + textView.textContainerOrigin.y
    guard y < visible.minY + 20 || y > visible.maxY - 40 else { return }
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, y - visible.height / 3)))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    lm.textViewportLayoutController.layoutViewport()
  }
}
