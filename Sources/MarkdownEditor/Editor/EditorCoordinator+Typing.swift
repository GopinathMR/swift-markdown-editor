import AppKit

extension EditorCoordinator {
  // MARK: Spell check only in prose

  /// Drop spelling results in code, math, links, front matter and hidden syntax.
  func textView(
    _ view: NSTextView, didCheckTextIn range: NSRange, types checkingTypes: NSTextCheckingTypes,
    options: [NSSpellChecker.OptionKey: Any] = [:], results: [NSTextCheckingResult],
    orthography: NSOrthography, wordCount: Int
  ) -> [NSTextCheckingResult] {
    results.filter { r in
      guard r.resultType == .spelling || r.resultType == .grammar, r.range.end <= storage.length,
        r.range.length > 0
      else { return true }
      return isProse(r.range)
    }
  }

  func isProse(_ r: NSRange) -> Bool {
    var prose = true
    storage.enumerateAttributes(in: r) { a, _, stop in
      let mono = (a[.font] as? NSFont)?.isFixedPitch == true
      if mono || a[.mdLink] != nil || a[.mdHidden] != nil {
        prose = false
        stop.pointee = true
      }
    }
    return prose
  }

  // MARK: Emoji completion

  /// After `:sm`, offer shortcodes through NSTextView's native completion list.
  func maybeCompleteEmoji() {
    let loc = textView.selectedRange().location
    let start = max(0, loc - 40)
    let before = text.substring(with: NSRange(location: start, length: loc - start))
    guard let m = before.firstMatch(of: #/:([a-z0-9_+\-]{2,})$/#),
      isProse(NSRange(location: max(0, loc - 1), length: 1)) || loc == 0
    else { return }
    if !EmojiTable.shared.completions(prefix: String(m.1)).isEmpty {
      DispatchQueue.main.async { [weak self] in self?.textView.complete(nil) }
    }
  }

  func textView(
    _ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
    indexOfSelectedItem index: UnsafeMutablePointer<Int>?
  ) -> [String] {
    let start = charRange.location
    guard start > 0, text.substring(with: NSRange(location: start - 1, length: 1)) == ":" else {
      return words
    }
    let prefix = text.substring(with: charRange)
    index?.pointee = 0
    return EmojiTable.shared.completions(prefix: prefix).map { "\($0):" }
  }
}
