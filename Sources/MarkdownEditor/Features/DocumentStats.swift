import Foundation

public struct DocumentStats: Sendable, Equatable {
  public var words = 0
  public var characters = 0
  public var lines = 0
  public var readingMinutes = 0.0
  public var selectionWords = 0
  public var selectionCharacters = 0

  public init() {}

  /// Words skip markdown syntax; characters include it. Each CJK character is one word.
  static func compute(_ text: String, model: DocumentModel?, wpm: Int) -> DocumentStats {
    var s = DocumentStats()
    s.characters = text.count
    s.lines = text.isEmpty ? 0 : text.components(separatedBy: .newlines).count
    s.words = wordCount(stripSyntax(text))
    s.readingMinutes = Double(s.words) / Double(max(1, wpm))
    return s
  }

  mutating func applySelection(_ sel: String) {
    selectionCharacters = sel.count
    selectionWords = sel.isEmpty ? 0 : Self.wordCount(Self.stripSyntax(sel))
  }

  static func wordCount(_ s: String) -> Int {
    var n = 0
    var cjk = 0
    var buffer = ""
    for ch in s {
      if ch.unicodeScalars.contains(where: isCJK) {
        cjk += 1
        buffer.append(" ")
      } else {
        buffer.append(ch)
      }
    }
    (buffer as NSString).enumerateSubstrings(
      in: NSRange(location: 0, length: (buffer as NSString).length),
      options: [.byWords, .substringNotRequired]
    ) { _, _, _, _ in n += 1 }
    return n + cjk
  }

  static func isCJK(_ u: Unicode.Scalar) -> Bool {
    switch u.value {
    case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3040...0x30FF, 0xAC00...0xD7AF, 0xF900...0xFAFF,
      0x20000...0x2A6DF:
      return true
    default: return false
    }
  }

  /// Drop list bullets, heading hashes, emphasis/code markers and link URLs.
  static func stripSyntax(_ s: String) -> String {
    var t = s
    let rules: [(String, String)] = [
      (#"(?m)^\s{0,3}#{1,6}\s+"#, ""), (#"(?m)^\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?"#, ""),
      (#"(?m)^\s*>\s?"#, ""), (#"!?\[([^\]]*)\]\([^)]*\)"#, "$1"), (#"[*_~=`]{1,3}"#, ""),
      (#"(?m)^\s*(?:---|\*\*\*|```.*|\|?\s*:?-+:?\s*(?:\|\s*:?-+:?\s*)*\|?)\s*$"#, ""),
      (#"\|"#, " "),
    ]
    for (p, r) in rules { t = t.replacingOccurrences(of: p, with: r, options: .regularExpression) }
    return t
  }
}
