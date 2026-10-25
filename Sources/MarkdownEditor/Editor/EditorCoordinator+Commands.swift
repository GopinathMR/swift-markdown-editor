import AppKit

extension EditorCoordinator {
  func canPerform(_ c: EditorCommand) -> Bool {
    switch c {
    case .deleteTableRow: return blockAtCaret()?.kind == .table
    case .toggleSourceMode, .toggleFocusMode, .toggleTypewriterMode, .zoomIn, .zoomOut, .zoomReset,
      .find, .findAndReplace,
      .jumpTop, .jumpBottom, .jumpSelection, .copyAsMarkdown, .copyAsHTML, .pasteAsPlainText,
      .selectLine, .selectWord,
      .selectStyleScope, .deleteWord:
      return true
    default:
      return mode == .rendered || [.indent, .outdent].contains(c)
    }
  }

  private func blockAtCaret() -> Block? {
    model.innermostBlock(at: min(textView.selectedRange().location, max(0, text.length - 1)))?.block
  }

  func perform(_ c: EditorCommand) {
    guard canPerform(c) else { return }
    let sel = textView.selectedRange()
    switch c {
    case .heading(let n): setHeading(n)
    case .paragraph: setHeading(0)
    case .increaseHeading: setHeading(max(1, (currentHeadingLevel() ?? 7) - 1))
    case .decreaseHeading:
      let l = currentHeadingLevel() ?? 6
      setHeading(l >= 6 ? 0 : l + 1)
    case .table: insertTableWithPicker()
    case .codeFence: wrapBlock(open: "```", close: "```")
    case .mathBlock: wrapBlock(open: "$$", close: "$$")
    case .quote: togglePrefix("> ", pattern: #"^\s*>\s?"#)
    case .orderedList: togglePrefix("1. ", pattern: #"^\s*\d+[.)]\s+"#, numbered: true)
    case .unorderedList: togglePrefix("- ", pattern: #"^\s*[-*+]\s+(?!\[[ xX]\])"#)
    case .taskList: togglePrefix("- [ ] ", pattern: #"^\s*[-*+]\s+\[[ xX]\]\s+"#)
    case .indent: _ = indentLines(sel, backward: false, unit: "    ")
    case .outdent: _ = indentLines(sel, backward: true, unit: "    ")
    case .horizontalRule: insertBlock("---", caret: 3)
    case .footnote: insertFootnote()
    case .toc: insertBlock("[toc]", caret: 5)
    case .frontMatter:
      if model.frontMatter == nil {
        replace(
          NSRange(location: 0, length: 0), with: "---\(eol)\(eol)---\(eol)",
          selectAfter: NSRange(location: 3 + eol.utf16.count, length: 0))
      }
    case .strong: toggleWrap("**")
    case .emphasis: toggleWrap("*")
    case .underline: toggleWrap("<u>", "</u>")
    case .inlineCode: toggleWrap("`")
    case .strikethrough: toggleWrap("~~")
    case .highlight: toggleWrap("==")
    case .inlineMath: toggleWrap("$")
    case .link: insertLink()
    case .image: insertImageCommand()
    case .clearFormat: clearFormat()
    case .selectLine: textView.setSelectedRange(trimNL(text.lineRange(for: sel)))
    case .selectStyleScope: selectStyleScope()
    case .selectWord: textView.selectWord(nil)
    case .deleteWord:
      textView.selectWord(nil)
      textView.delete(nil)
    case .deleteTableRow: deleteTableRowAtCaret()
    case .jumpTop: jump(to: 0)
    case .jumpBottom: jump(to: text.length)
    case .jumpSelection: reveal(location: sel.location)
    case .copyAsMarkdown: copyAsMarkdown()
    case .copyAsHTML: copyAsHTML()
    case .pasteAsPlainText: _ = handlePaste(plain: true)
    case .toggleSourceMode: controller?.mode = mode == .rendered ? .source : .rendered
    case .toggleFocusMode: controller?.isFocusMode.toggle()
    case .toggleTypewriterMode: controller?.isTypewriterMode.toggle()
    case .zoomIn: controller?.zoom += 0.1
    case .zoomOut: controller?.zoom -= 0.1
    case .zoomReset: controller?.zoom = 1
    case .find: showFind(replace: false)
    case .findAndReplace: showFind(replace: true)
    }
  }

  private func trimNL(_ r: NSRange) -> NSRange {
    var r = r
    while r.length > 0, [0x0A, 0x0D].contains(text.character(at: r.end - 1)) { r.length -= 1 }
    return r
  }

  // MARK: Block commands

  private func currentHeadingLevel() -> Int? {
    switch blockAtCaret()?.kind {
    case .heading(let l), .setextHeading(let l): return l
    default: return nil
    }
  }

  /// `level` 0 = paragraph.
  private func setHeading(_ level: Int) {
    let sel = textView.selectedRange()
    let lr = trimNL(text.lineRange(for: NSRange(location: sel.location, length: 0)))
    let line = text.substring(with: lr)
    let stripped = line.replacingOccurrences(
      of: #"^\s{0,3}#{1,6}\s*"#, with: "", options: .regularExpression)
    let prefix = level > 0 ? String(repeating: "#", count: level) + " " : ""
    let new = prefix + stripped
    let caretInLine = max(0, sel.location - lr.location - (line.utf16.count - stripped.utf16.count))
    replace(
      lr, with: new,
      selectAfter: NSRange(
        location: lr.location + prefix.utf16.count + min(caretInLine, stripped.utf16.count),
        length: 0))
  }

  /// Insert `block` as its own paragraph at the caret line, caret `caret` chars in.
  private func insertBlock(_ block: String, caret: Int) {
    let sel = textView.selectedRange()
    let lr = trimNL(text.lineRange(for: NSRange(location: sel.location, length: 0)))
    let lineEmpty = text.substring(with: lr).trimmingCharacters(in: .whitespaces).isEmpty
    if lineEmpty {
      replace(lr, with: block, selectAfter: NSRange(location: lr.location + caret, length: 0))
    } else {
      let at = lr.end
      replace(
        NSRange(location: at, length: 0), with: eol + eol + block,
        selectAfter: NSRange(location: at + 2 * eol.utf16.count + caret, length: 0))
    }
  }

  private func wrapBlock(open: String, close: String) {
    let sel = textView.selectedRange()
    if sel.length > 0 {
      let inner = text.substring(with: sel)
      replace(
        sel, with: open + eol + inner + eol + close,
        selectAfter: NSRange(
          location: sel.location + open.utf16.count + eol.utf16.count, length: sel.length))
    } else {
      insertBlock(open + eol + eol + close, caret: open.utf16.count + eol.utf16.count)
    }
  }

  private func togglePrefix(_ prefix: String, pattern: String, numbered: Bool = false) {
    let sel = textView.selectedRange()
    let lines = trimNL(text.lineRange(for: sel))
    let body = text.substring(with: lines)
    let parts = body.components(separatedBy: eol)
    let re = try! NSRegularExpression(pattern: pattern)
    let allHave = parts.allSatisfy {
      re.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil
        || $0.isEmpty
    }
    var out: [String] = []
    var n = 1
    for p in parts {
      let ns = p as NSString
      // Strip any other list/quote prefix first so the commands switch between kinds.
      let stripped = re.stringByReplacingMatches(
        in: p, range: NSRange(location: 0, length: ns.length), withTemplate: "")
      if allHave {
        out.append(stripped)
      } else {
        let clean = stripped.replacingOccurrences(
          of: #"^\s*(?:[-*+]\s+(?:\[[ xX]\]\s+)?|\d+[.)]\s+)"#, with: "",
          options: .regularExpression)
        out.append((numbered ? "\(n). " : prefix) + clean)
        n += 1
      }
    }
    let new = out.joined(separator: eol)
    replace(
      lines, with: new, selectAfter: NSRange(location: lines.location + new.utf16.count, length: 0))
  }

  private func insertFootnote() {
    let used = Set(model.footnoteDefinitions.keys)
    var n = 1
    while used.contains("\(n)") { n += 1 }
    let sel = textView.selectedRange()
    let ref = "[^\(n)]"
    let def = "\(eol)\(eol)[^\(n)]: "
    // One undo step: definition at the end first, then the reference.
    textView.undoManager?.beginUndoGrouping()
    replace(NSRange(location: text.length, length: 0), with: def)
    replace(
      NSRange(location: sel.location, length: 0), with: ref,
      selectAfter: NSRange(location: text.length, length: 0))
    textView.undoManager?.endUndoGrouping()
    textView.scrollRangeToVisible(textView.selectedRange())
  }

  // MARK: Inline commands

  private func toggleWrap(_ open: String, _ close: String? = nil) {
    let close = close ?? open
    let sel = textView.selectedRange()
    let o = open.utf16.count
    let c = close.utf16.count
    // Already wrapped (markers just outside the selection) → unwrap.
    if sel.location >= o, sel.end + c <= text.length,
      text.substring(with: NSRange(location: sel.location - o, length: o)) == open,
      text.substring(with: NSRange(location: sel.end, length: c)) == close
    {
      let inner = text.substring(with: sel)
      replace(
        NSRange(location: sel.location - o, length: sel.length + o + c), with: inner,
        selectAfter: NSRange(location: sel.location - o, length: sel.length))
      return
    }
    // Selection includes the markers → unwrap.
    let s = text.substring(with: sel)
    if sel.length >= o + c, s.hasPrefix(open), s.hasSuffix(close) {
      let inner = String(s.dropFirst(open.count).dropLast(close.count))
      replace(
        sel, with: inner, selectAfter: NSRange(location: sel.location, length: inner.utf16.count))
      return
    }
    replace(
      sel, with: open + s + close,
      selectAfter: NSRange(location: sel.location + o, length: sel.length))
  }

  private func insertLink() {
    let sel = textView.selectedRange()
    let s = text.substring(with: sel)
    let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(
      in: .whitespacesAndNewlines)
    let url = clip.flatMap { URL(string: $0)?.scheme != nil ? $0 : nil } ?? ""
    let new = "[\(s)](\(url))"
    let caret =
      s.isEmpty ? sel.location + 1 : sel.location + s.utf16.count + 3 + (url as NSString).length
    replace(sel, with: new, selectAfter: NSRange(location: caret, length: 0))
  }

  private func clearFormat() {
    let sel = textView.selectedRange()
    guard sel.length > 0 else { return }
    var markers: [NSRange] = []
    for e in model.entries
    where NSIntersectionRange(e.range, sel).length > 0 || e.range.contains(sel.location) {
      forEachInline(e.block) { i in
        for m in i.markers {
          let r = m.shifted(by: e.start)
          if NSIntersectionRange(r, sel).length == r.length { markers.append(r) }
        }
      }
    }
    let s = NSMutableString(string: text.substring(with: sel))
    for m in markers.sorted(by: { $0.location > $1.location }) {
      s.deleteCharacters(in: m.shifted(by: -sel.location))
    }
    replace(sel, with: s as String, selectAfter: NSRange(location: sel.location, length: s.length))
  }

  private func selectStyleScope() {
    let sel = textView.selectedRange()
    if let (i, off) = model.inline(at: sel.location) {
      let r = i.range.shifted(by: off)
      if i.markers.count >= 2 {
        let inner = NSRange(
          location: i.markers.first!.end + off,
          length: i.markers.last!.location - i.markers.first!.end)
        textView.setSelectedRange(sel == inner ? r : inner)
      } else {
        textView.setSelectedRange(r)
      }
    } else if let (b, off) = model.innermostBlock(at: sel.location) {
      textView.setSelectedRange(trimNL(b.range.shifted(by: off)))
    }
  }
}
