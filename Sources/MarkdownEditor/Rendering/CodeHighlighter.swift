import AppKit
import CodeEditLanguages
import SwiftTreeSitter

/// Syntax colours for fenced code, from CodeEditLanguages' tree-sitter grammars and
/// highlight queries. Results are cached per (language, code) so restyles are free.
@MainActor
final class CodeHighlighter {
  private var parsers: [TreeSitterLanguage: Parser] = [:]
  private var cache: [String: [(NSRange, String)]] = [:]

  /// Fence info names people write → CodeEditLanguages' language.
  private static let aliases: [String: String] = [
    "js": "javascript", "node": "javascript", "ts": "typescript", "py": "python",
    "python3": "python",
    "sh": "bash", "shell": "bash", "zsh": "bash", "console": "bash", "objective-c": "objc",
    "objectivec": "objc", "c++": "cpp", "cc": "cpp", "hpp": "cpp", "cs": "c-sharp",
    "csharp": "c-sharp",
    "c#": "c-sharp", "yml": "yaml", "rb": "ruby", "rs": "rust", "kt": "kotlin", "golang": "go",
    "md": "markdown", "html5": "html", "xml": "html", "svg": "html", "docker": "dockerfile",
    "jsonc": "json", "json5": "json", "pl": "perl", "ex": "elixir", "exs": "elixir",
    "hs": "haskell",
    "ml": "ocaml", "jl": "julia", "postgres": "sql", "mysql": "sql", "sv": "verilog", "jsx": "jsx",
    "tsx": "tsx",
  ]

  static func language(named name: String) -> CodeLanguage? {
    let key = name.lowercased().trimmingCharacters(in: .whitespaces)
    let resolved = aliases[key] ?? key
    return CodeLanguage.allLanguages.first {
      $0.id != .plainText
        && ($0.tsName == resolved || $0.id.rawValue == resolved || $0.extensions.contains(resolved))
    }
  }

  /// Names shown in the language picker.
  static var languageNames: [String] {
    CodeLanguage.allLanguages.filter { $0.id != .plainText && $0.id != .markdownInline }.map(
      \.tsName
    )
    .sorted()
  }

  func highlight(_ code: String, language: String, colors: [String: NSColor]) -> [(
    NSRange, NSColor
  )] {
    let key = language + "\u{0}" + code
    let captures: [(NSRange, String)]
    if let c = cache[key] {
      captures = c
    } else {
      captures = parse(code, language: language)
      if cache.count > 400 { cache.removeAll() }
      cache[key] = captures
    }
    return captures.compactMap { r, name in color(for: name, in: colors).map { (r, $0) } }
  }

  /// `function.method.call` → tries `function.method.call`, `function.method`, `function`.
  private func color(for name: String, in colors: [String: NSColor]) -> NSColor? {
    var parts = name.split(separator: ".")
    while !parts.isEmpty {
      if let c = colors[parts.joined(separator: ".")] { return c }
      parts.removeLast()
    }
    return nil
  }

  private var queries: [TreeSitterLanguage: Query] = [:]

  /// CodeEditLanguages builds `<resourceURL>/Resources/tree-sitter-x/…`, but in a SwiftPM
  /// bundle `resourceURL` already ends in `Resources`, so its own loader finds nothing.
  /// Load the files ourselves, trying both spellings, plus inherited and extra highlights.
  private func query(for lang: CodeLanguage) -> Query? {
    if let q = queries[lang.id] { return q }
    func read(_ url: URL?) -> Data? {
      guard let url else { return nil }
      if let d = try? Data(contentsOf: url) { return d }
      let fixed = url.path.replacingOccurrences(of: "/Resources/Resources/", with: "/Resources/")
      return try? Data(contentsOf: URL(fileURLWithPath: fixed))
    }
    guard let tsLanguage = lang.language, var data = read(lang.queryURL) else { return nil }
    if let parent = read(lang.parentQueryURL) { data = parent + Data("\n".utf8) + data }
    for extra in lang.additionalHighlights ?? [] where extra.hasPrefix("highlights") {
      let url = lang.queryURL?.deletingLastPathComponent().appendingPathComponent(extra + ".scm")
      if let d = read(url) { data += Data("\n".utf8) + d }
    }
    guard let q = try? Query(language: tsLanguage, data: data) else { return nil }
    queries[lang.id] = q
    return q
  }

  private func parse(_ code: String, language: String) -> [(NSRange, String)] {
    guard let lang = Self.language(named: language), let tsLanguage = lang.language,
      let query = query(for: lang)
    else { return [] }
    let parser = parsers[lang.id] ?? Parser()
    if parsers[lang.id] == nil {
      guard (try? parser.setLanguage(tsLanguage)) != nil else { return [] }
      parsers[lang.id] = parser
    }
    guard let tree = parser.parse(code) else { return [] }
    let highlights = query.execute(in: tree).resolve(with: .init(string: code)).highlights()
    return highlights.map { ($0.range, $0.name) }
  }
}
