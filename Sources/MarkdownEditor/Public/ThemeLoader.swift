import AppKit
import TOMLKit

/// A theme file problem, naming the TOML line or key.
public struct ThemeError: Error, Equatable, CustomStringConvertible {
  public let description: String
}

extension EditorTheme {
  /// Load a TOML theme. Every key is optional; missing ones keep the built-in values.
  ///
  /// ```toml
  /// [light]
  /// body-font = { family = "New York", size = 17 }
  /// mono-font = { family = "SF Mono" }
  /// heading-scales = [2.0, 1.6, 1.35, 1.15, 1.0, 0.9]
  /// line-spacing = 4
  /// paragraph-spacing = 10
  /// max-width = 860
  /// heading-numbering = true
  /// [light.colors]
  /// text = "#333333"
  /// link = "#4183C4"
  /// [light.code-tokens]
  /// keyword = "#A626A4"
  /// [dark]
  /// # same keys
  /// ```
  public static func load(toml: String) throws -> EditorTheme {
    let root: TOMLTable
    do {
      root = try TOMLTable(string: toml)
    } catch let e as TOMLParseError {
      throw ThemeError(description: "Line \(e.source.begin.line): \(e.description)")
    } catch {
      throw ThemeError(description: "\(error)")
    }
    for key in root.keys where !["light", "dark"].contains(key) {
      throw ThemeError(description: "Unknown section `\(key)` (expected `light` or `dark`)")
    }
    var theme = EditorTheme.default
    if let t = root["light"] { theme.light = try style(t, base: .defaultLight, section: "light") }
    if let t = root["dark"] { theme.dark = try style(t, base: .defaultDark, section: "dark") }
    return theme
  }

  private static func style(_ value: TOMLValueConvertible, base: ThemeStyle, section: String) throws
    -> ThemeStyle
  {
    guard let t = value.table else { throw ThemeError(description: "`\(section)` must be a table") }
    var s = base
    func number(_ key: String) throws -> CGFloat? {
      guard let v = t[key] else { return nil }
      if let d = v.double { return CGFloat(d) }
      if let i = v.int { return CGFloat(i) }
      throw ThemeError(description: "`\(section).\(key)` must be a number")
    }
    func font(_ key: String) throws -> (String?, CGFloat?)? {
      guard let v = t[key] else { return nil }
      if let name = v.string { return (name, nil) }
      guard let f = v.table else {
        throw ThemeError(description: "`\(section).\(key)` must be a string or { family, size }")
      }
      let size = f["size"].flatMap { $0.double.map { CGFloat($0) } ?? $0.int.map { CGFloat($0) } }
      return (f["family"]?.string, size)
    }
    let known: Set<String> = [
      "body-font", "mono-font", "base-size", "heading-scales", "line-spacing", "paragraph-spacing",
      "max-width",
      "heading-numbering", "colors", "code-tokens",
    ]
    for key in t.keys where !known.contains(key) {
      throw ThemeError(description: "Unknown key `\(section).\(key)`")
    }
    if let (family, size) = try font("body-font") {
      s.bodyFont = family
      if let size { s.baseSize = size }
    }
    if let (family, _) = try font("mono-font") { s.monoFont = family }
    if let v = try number("base-size") { s.baseSize = v }
    if let v = try number("line-spacing") { s.lineSpacing = v }
    if let v = try number("paragraph-spacing") { s.paragraphSpacing = v }
    if let v = try number("max-width") { s.maxWidth = v > 0 ? v : nil }
    if let v = t["heading-numbering"] {
      guard let b = v.bool else {
        throw ThemeError(description: "`\(section).heading-numbering` must be true or false")
      }
      s.headingNumbering = b
    }
    if let v = t["heading-scales"] {
      let values =
        v.array.map { Array($0).compactMap { $0.double ?? $0.int.map(Double.init) } } ?? []
      guard values.count == 6 else {
        throw ThemeError(description: "`\(section).heading-scales` needs six numbers")
      }
      s.headingScales = values.map { CGFloat($0) }
    }
    if let v = t["colors"] {
      guard let c = v.table else {
        throw ThemeError(description: "`\(section).colors` must be a table")
      }
      var colors = s.colors
      let paths: [String: WritableKeyPath<ThemeColors, String>] = [
        "background": \.background, "text": \.text, "secondary-text": \.secondaryText,
        "heading": \.heading,
        "link": \.link, "code-background": \.codeBackground, "code-text": \.codeText,
        "quote-bar": \.quoteBar,
        "highlight": \.highlight, "rule": \.hr, "table-border": \.tableBorder,
        "table-header": \.tableHeader,
        "selection": \.selection, "note": \.note, "tip": \.tip, "important": \.important,
        "warning": \.warning,
        "caution": \.caution,
      ]
      for key in c.keys {
        guard let path = paths[key] else {
          throw ThemeError(description: "Unknown colour `\(section).colors.\(key)`")
        }
        guard let hex = c[key]?.string,
          hex.hasPrefix("#") || NSColor.cssNamed[hex.lowercased()] != nil
        else {
          throw ThemeError(
            description: "`\(section).colors.\(key)` must be a colour like \"#336699\"")
        }
        colors[keyPath: path] = hex
      }
      s.colors = colors
    }
    if let v = t["code-tokens"] {
      guard let c = v.table else {
        throw ThemeError(description: "`\(section).code-tokens` must be a table")
      }
      for key in c.keys {
        guard let hex = c[key]?.string else {
          throw ThemeError(description: "`\(section).code-tokens.\(key)` must be a colour")
        }
        s.codeTokens[key] = hex
      }
    }
    return s
  }
}

extension ThemeStyle {
  /// The same look as CSS, for HTML/PDF/PNG export.
  public func css() -> String {
    let c = colors
    let body = bodyFont.map { "\"\($0)\", " } ?? ""
    let mono = monoFont.map { "\"\($0)\", " } ?? ""
    let h = headingScales.enumerated().map {
      "h\($0.offset + 1) { font-size: \(String(format: "%.2f", $0.element))em; }"
    }
    .joined(separator: "\n")
    let numbering =
      headingNumbering
      ? """
      body { counter-reset: h1; }
      h1 { counter-reset: h2; } h2 { counter-reset: h3; } h3 { counter-reset: h4; }
      h1:before { counter-increment: h1; content: counter(h1) ". "; }
      h2:before { counter-increment: h2; content: counter(h1) "." counter(h2) " "; }
      h3:before { counter-increment: h3; content: counter(h1) "." counter(h2) "." counter(h3) " "; }
      """ : ""
    return """
      :root { color-scheme: light dark; }
      * { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
      body { font-family: \(body)-apple-system, "Helvetica Neue", Helvetica, sans-serif; font-size: \(Int(baseSize))px;
        line-height: \(String(format: "%.2f", 1.35 + lineSpacing / baseSize)); color: \(c.text); background: \(c.background);
        max-width: \(Int(maxWidth ?? 900))px; margin: 0 auto; padding: 30px; }
      h1, h2, h3, h4, h5, h6 { color: \(c.heading); line-height: 1.25; margin: 1.2em 0 0.6em; }
      \(h)
      p, ul, ol, blockquote, pre, table { margin: 0 0 \(Int(paragraphSpacing))px; }
      a { color: \(c.link); text-decoration: none; }
      code { font-family: \(mono)ui-monospace, Menlo, monospace; font-size: 0.88em; background: \(c.codeBackground);
        color: \(c.codeText); padding: 1px 4px; border-radius: 3px; }
      pre { background: \(c.codeBackground); padding: 10px 12px; border-radius: 6px; overflow: auto; white-space: pre-wrap; }
      pre code { background: none; padding: 0; }
      blockquote { border-left: 3px solid \(c.quoteBar); color: \(c.secondaryText); padding: 0 1em; margin-left: 0; }
      mark { background: \(c.highlight); }
      hr { border: none; border-top: 2px solid \(c.hr); }
      table { border-collapse: collapse; }
      th, td { border: 1px solid \(c.tableBorder); padding: 6px 10px; }
      th { background: \(c.tableHeader); }
      li.task { list-style: none; } li.task input { margin: 0 0.4em 0 -1.3em; }
      .callout { border-left: 3px solid; padding: 0.2em 1em; margin: 0 0 \(Int(paragraphSpacing))px; }
      .callout-title { font-weight: 600; margin-bottom: 0.2em; }
      .callout-note { border-color: \(c.note); } .callout-note .callout-title { color: \(c.note); }
      .callout-tip { border-color: \(c.tip); } .callout-tip .callout-title { color: \(c.tip); }
      .callout-important { border-color: \(c.important); } .callout-important .callout-title { color: \(c.important); }
      .callout-warning { border-color: \(c.warning); } .callout-warning .callout-title { color: \(c.warning); }
      .callout-caution { border-color: \(c.caution); } .callout-caution .callout-title { color: \(c.caution); }
      .math-block, .diagram { text-align: center; margin: 1em 0; }
      .diagram svg { max-width: 100%; height: auto; }
      img { max-width: 100%; }
      .footnotes { font-size: 0.9em; color: \(c.secondaryText); }
      nav.toc ul { list-style: none; padding-left: 0; }
      \(["toc-h2", "toc-h3", "toc-h4", "toc-h5", "toc-h6"].enumerated().map { ".\($0.element) { padding-left: \(($0.offset + 1) * 18)px; }" }.joined(separator: " "))
      \(numbering)
      @media print { body { max-width: none; padding: 0; } pre, table, img, .diagram, .math-block { page-break-inside: avoid; } }
      """
  }
}
