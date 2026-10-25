import AppKit

extension EditorCoordinator {
  var eol: String { text.range(of: "\r\n").location != NSNotFound ? "\r\n" : "\n" }

  private var caret: NSRange { textView.selectedRange() }

  private func line(at loc: Int) -> (range: NSRange, content: String) {
    let r = text.lineRange(for: NSRange(location: min(loc, max(0, text.length)), length: 0))
    var s = text.substring(with: r)
    while s.hasSuffix("\n") || s.hasSuffix("\r") { s.removeLast() }
    return (r, s)
  }

  private func blockKind(at loc: Int) -> BlockKind? {
    model.innermostBlock(at: min(loc, max(0, text.length - 1)))?.block.kind
  }

  private func isInCode(_ loc: Int) -> Bool {
    switch blockKind(at: loc) {
    case .code, .diagram, .math, .frontMatter: return true
    default: return false
    }
  }

  // MARK: Return

  func handleNewline(shift: Bool) -> Bool {
    guard mode == .rendered else { return false }
    let sel = caret
    let (lineRange, content) = line(at: sel.location)
    let nl = eol
    let ns = content as NSString

    // Opening a fence or math block closes it for you.
    if sel.length == 0, sel.location == lineRange.location + ns.length {
      let trimmed = content.trimmingCharacters(in: .whitespaces)
      if let m = trimmed.firstMatch(of: #/^(`{3,}|~{3,})[^`]*$/#), isUnclosedFenceOpening(lineRange)
      {
        let fence = String(m.1)
        return insert(nl + nl + fence, caretOffset: nl.utf16.count)
      }
      if trimmed == "$$",
        blockKind(at: sel.location) == .paragraph || blockKind(at: sel.location) == nil
      {
        return insert(nl + nl + "$$", caretOffset: nl.utf16.count)
      }
      if trimmed == "---", lineRange.location == 0,
        text.length == ns.length || text.length == lineRange.length
      {
        return insert(nl + nl + "---", caretOffset: nl.utf16.count)
      }
    }
    if isInCode(sel.location) { return insertKeepingIndent(content, nl) }

    if shift { return insert(nl, caretOffset: nl.utf16.count) }

    // Lists: continue with the next marker; an empty item ends the list.
    if let m = content.firstMatch(of: #/^(\s*(?:>\s?)*)([-*+]|\d+[.)])(\s+)(\[[ xX]\]\s+)?/#) {
      let prefixLen = m.0.utf16.count
      if ns.length <= prefixLen {
        // Empty item: drop the marker, leave a blank line.
        replace(
          NSRange(location: lineRange.location, length: ns.length), with: "",
          selectAfter: NSRange(location: lineRange.location, length: 0))
        return true
      }
      var marker = String(m.2)
      if let n = Int(marker.dropLast()) { marker = "\(n + 1)" + String(marker.last!) }
      let task = m.4 != nil ? "[ ] " : ""
      return insert(nl + String(m.1) + marker + String(m.3) + task, caretOffset: nil)
    }
    // Quotes: keep the `>` prefix; an empty quote line ends the quote.
    if let m = content.firstMatch(of: #/^(\s*(?:>\s?)+)/#) {
      if ns.length <= m.0.utf16.count {
        replace(
          NSRange(location: lineRange.location, length: ns.length), with: "",
          selectAfter: NSRange(location: lineRange.location, length: 0))
        return true
      }
      return insert(nl + String(m.1), caretOffset: nil)
    }
    // Headings and paragraphs: Return starts a new paragraph (a blank line in source).
    if content.trimmingCharacters(in: .whitespaces).isEmpty { return insert(nl, caretOffset: nil) }
    return insert(nl + nl, caretOffset: nil)
  }

  /// The line opens a fence that nothing closes yet (the grammar runs it to the end).
  private func isUnclosedFenceOpening(_ line: NSRange) -> Bool {
    guard let (b, off) = model.innermostBlock(at: line.location) else { return true }
    switch b.kind {
    case .code, .diagram:
      return b.markers.count == 1 && NSLocationInRange(b.markers[0].location + off, line)
    default:
      return true
    }
  }

  private func insertKeepingIndent(_ line: String, _ nl: String) -> Bool {
    let indent = String(line.prefix { $0 == " " || $0 == "\t" })
    return insert(nl + indent, caretOffset: nil)
  }

  /// Insert at the selection; caret ends at `caretOffset` into the insertion (or its end).
  @discardableResult
  func insert(_ s: String, caretOffset: Int?) -> Bool {
    let sel = caret
    let after = NSRange(location: sel.location + (caretOffset ?? s.utf16.count), length: 0)
    return replace(sel, with: s, selectAfter: after)
  }

  // MARK: Tab

  func handleTab(backward: Bool) -> Bool {
    guard mode == .rendered else { return false }
    let sel = caret
    if isInCode(sel.location) {
      return indentLines(
        sel, backward: backward, unit: String(repeating: " ", count: preferences.tabSize))
    }
    let (_, content) = line(at: sel.location)
    if content.firstMatch(of: #/^\s*([-*+]|\d+[.)])\s/#) != nil {
      return indentLines(sel, backward: backward, unit: "    ")
    }
    return backward
  }

  func indentLines(_ sel: NSRange, backward: Bool, unit: String) -> Bool {
    let lines = text.lineRange(for: sel)
    var out = ""
    var removedFirst = 0
    var delta = 0
    let body = text.substring(with: lines)
    let parts = body.components(separatedBy: "\n")
    for (i, p) in parts.enumerated() {
      var line = p
      if i == parts.count - 1, line.isEmpty, body.hasSuffix("\n") {
        out += ""
        continue
      }
      if backward {
        var n = 0
        while n < unit.count, line.hasPrefix(" ") {
          line.removeFirst()
          n += 1
        }
        if n == 0, line.hasPrefix("\t") {
          line.removeFirst()
          n = 1
        }
        if i == 0 { removedFirst = n }
        delta -= n
      } else {
        line = unit + line
        delta += unit.utf16.count
      }
      out += line + (i < parts.count - 1 ? "\n" : "")
    }
    let newSel: NSRange
    if backward {
      newSel = NSRange(
        location: max(lines.location, sel.location - removedFirst),
        length: max(0, sel.length + delta + removedFirst))
    } else {
      newSel = NSRange(
        location: sel.location + unit.utf16.count,
        length: sel.length == 0 ? 0 : sel.length + delta - unit.utf16.count)
    }
    replace(
      lines, with: out,
      selectAfter: NSRange(
        location: min(newSel.location, lines.location + out.utf16.count), length: newSel.length))
    return true
  }

  // MARK: Typed characters: auto-pair, wrap, smart punctuation

  private static let bracketPairs: [String: String] = [
    "(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'",
  ]
  private static let markdownPairs: [String: String] = ["*": "*", "_": "_", "`": "`"]
  private static let wrapOnly: Set<String> = ["~", "=", "^", "$"]

  func handleInsert(_ s: String, replacementRange: NSRange) -> Bool {
    guard mode == .rendered, replacementRange.location == NSNotFound, s.count == 1 else {
      return false
    }
    let sel = caret
    let inCode = isInCode(sel.location) || isInInlineCode(sel.location)
    // Wrap a selection in a pairable symbol.
    if sel.length > 0, !inCode {
      let close: String? =
        (preferences.autoPairBrackets ? Self.bracketPairs[s] : nil)
        ?? (preferences.autoPairMarkdown ? Self.markdownPairs[s] : nil)
        ?? (Self.wrapOnly.contains(s) && wrapAllowed(s) ? s : nil)
      if let close {
        let inner = text.substring(with: sel)
        let doubled = (s == "~" || s == "=") && preferences.autoPairMarkdown
        let open = doubled ? s + s : s
        let end = doubled ? close + close : close
        return replace(
          sel, with: open + inner + end,
          selectAfter: NSRange(location: sel.location + open.utf16.count, length: sel.length))
      }
    }
    guard sel.length == 0 else { return false }
    // Step over a closing character we inserted.
    if sel.location < text.length {
      let next = text.substring(with: NSRange(location: sel.location, length: 1))
      let closers: Set<String> = [")", "]", "}", "\"", "'"]
      if next == s,
        (preferences.autoPairBrackets && closers.contains(s))
          || (preferences.autoPairMarkdown && Self.markdownPairs[s] != nil)
      {
        textView.setSelectedRange(NSRange(location: sel.location + 1, length: 0))
        return true
      }
    }
    if !inCode {
      if preferences.autoPairBrackets, let close = Self.bracketPairs[s],
        shouldPair(s, at: sel.location)
      {
        return insert(s + close, caretOffset: 1)
      }
      if preferences.autoPairMarkdown, let close = Self.markdownPairs[s],
        shouldPair(s, at: sel.location)
      {
        return insert(s + close, caretOffset: 1)
      }
      if preferences.smartPunctuation, s == ".", sel.location >= 2,
        text.substring(with: NSRange(location: sel.location - 2, length: 2)) == ".."
      {
        return replace(
          NSRange(location: sel.location - 2, length: 2), with: "…",
          selectAfter: NSRange(location: sel.location - 1, length: 0))
      }
    } else if preferences.autoPairBrackets, isInCode(sel.location),
      let close = ["(": ")", "[": "]", "{": "}"][s]
    {
      return insert(s + close, caretOffset: 1)
    }
    return false
  }

  private func wrapAllowed(_ s: String) -> Bool {
    switch s {
    case "=": return preferences.highlight
    case "^": return preferences.superscript
    case "$": return preferences.inlineMath
    default: return true
    }
  }

  /// Pair only before whitespace/closing punctuation, and not inside a word (it's → it's).
  private func shouldPair(_ s: String, at loc: Int) -> Bool {
    if loc < text.length {
      let next = Character(UnicodeScalar(text.character(at: loc)) ?? " ")
      if !(next.isWhitespace || ")]}.,;:".contains(next)) { return false }
    }
    if s == "'" || s == "\"" || s == "_" || s == "*", loc > 0 {
      let prev = Character(UnicodeScalar(text.character(at: loc - 1)) ?? " ")
      if prev.isLetter || prev.isNumber { return false }
    }
    if s == "*" || s == "_" {
      // Not at the start of a line: `* ` is a list marker.
      let lineStart = text.lineRange(for: NSRange(location: loc, length: 0)).location
      if text.substring(with: NSRange(location: lineStart, length: loc - lineStart))
        .trimmingCharacters(in: .whitespaces).isEmpty
      {
        return false
      }
    }
    return true
  }

  private func isInInlineCode(_ loc: Int) -> Bool {
    if let (i, _) = model.inline(at: loc),
      i.kind == .code || { if case .math = i.kind { return true } else { return false } }()
    {
      return true
    }
    return false
  }

  func handleDeleteBackward() -> Bool {
    guard mode == .rendered else { return false }
    let sel = caret
    guard sel.length == 0, sel.location > 0, sel.location < text.length else { return false }
    let prev = text.substring(with: NSRange(location: sel.location - 1, length: 1))
    let next = text.substring(with: NSRange(location: sel.location, length: 1))
    // Delete an empty auto-paired pair together.
    if let close = Self.bracketPairs[prev]
      ?? (preferences.autoPairMarkdown ? Self.markdownPairs[prev] : nil), close == next
    {
      return replace(
        NSRange(location: sel.location - 1, length: 2), with: "",
        selectAfter: NSRange(location: sel.location - 1, length: 0))
    }
    return false
  }

  func handleKeyDown(_ event: NSEvent) -> Bool { false }

  /// Smart quotes/dashes and text replacement only in prose, never in code or math.
  func updateSubstitutionContext() {
    let loc = caret.location
    let prose = !(isInCode(loc) || isInInlineCode(loc))
    textView.isAutomaticQuoteSubstitutionEnabled =
      prose && preferences.smartPunctuation && mode == .rendered
    textView.isAutomaticDashSubstitutionEnabled =
      prose && preferences.smartPunctuation && mode == .rendered
    textView.isAutomaticTextReplacementEnabled = prose && mode == .rendered
  }
}
