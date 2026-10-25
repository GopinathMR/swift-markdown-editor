import Foundation

enum HTMLEntities {
  // ponytail: the entities people actually type; add more when someone needs them.
  private static let named: [String: String] = [
    "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
    "copy": "©", "reg": "®", "trade": "™", "mdash": "—", "ndash": "–", "hellip": "…",
    "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔", "lArr": "⇐", "rArr": "⇒",
    "times": "×", "divide": "÷", "deg": "°", "plusmn": "±", "middot": "·", "bull": "•",
    "laquo": "«", "raquo": "»", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
    "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "sect": "§", "para": "¶",
    "hearts": "♥", "spades": "♠", "clubs": "♣", "diams": "♦", "check": "✓", "infin": "∞",
    "ne": "≠", "le": "≤", "ge": "≥", "asymp": "≈", "frac12": "½", "frac14": "¼", "frac34": "¾",
    "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "pi": "π", "sigma": "σ", "mu": "μ",
    "emsp": "\u{2003}", "ensp": "\u{2002}", "thinsp": "\u{2009}", "zwj": "\u{200D}",
  ]

  /// `&copy;`, `&#169;`, `&#xA9;` → "©".
  static func decode(_ entity: String) -> String? {
    guard entity.hasPrefix("&"), entity.hasSuffix(";") else { return nil }
    let body = entity.dropFirst().dropLast()
    if body.hasPrefix("#x") || body.hasPrefix("#X") {
      return UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map {
        String(Character($0))
      }
    }
    if body.hasPrefix("#") {
      return UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
    }
    return named[String(body)]
  }
}

/// gemoji shortcodes (`:smile:` → 😄), loaded once from the bundled TSV.
final class EmojiTable: Sendable {
  static let shared = EmojiTable()
  let codes: [String: String]
  let names: [String]

  private init() {
    var codes: [String: String] = [:]
    if let url = Bundle.module.url(
      forResource: "emoji", withExtension: "tsv", subdirectory: "Resources/gemoji"),
      let s = try? String(contentsOf: url, encoding: .utf8)
    {
      for line in s.split(separator: "\n") {
        let parts = line.split(separator: "\t", maxSplits: 1)
        if parts.count == 2 { codes[String(parts[0])] = String(parts[1]) }
      }
    }
    self.codes = codes
    self.names = codes.keys.sorted()
  }

  func emoji(for name: String) -> String? { codes[name] }

  func completions(prefix: String) -> [String] {
    names.filter { $0.hasPrefix(prefix) }.prefix(50).map { $0 }
  }
}
