import AppKit

/// A light and a dark style; the editor picks one from its effective appearance.
public struct EditorTheme: Sendable, Equatable {
  public var light: ThemeStyle
  public var dark: ThemeStyle

  public init(light: ThemeStyle, dark: ThemeStyle) {
    self.light = light
    self.dark = dark
  }

  public static let `default` = EditorTheme(light: .defaultLight, dark: .defaultDark)

  func style(dark isDark: Bool) -> ThemeStyle { isDark ? dark : light }
}

public struct ThemeStyle: Sendable, Equatable {
  /// `nil` = system font.
  public var bodyFont: String?
  public var monoFont: String?
  public var baseSize: CGFloat = 16
  /// Size multipliers for H1–H6.
  public var headingScales: [CGFloat] = [2.0, 1.6, 1.35, 1.15, 1.0, 0.9]
  public var colors: ThemeColors
  /// tree-sitter capture name (`keyword`, `string`, …) → hex colour.
  public var codeTokens: [String: String]
  public var lineSpacing: CGFloat = 4
  public var paragraphSpacing: CGFloat = 10
  public var maxWidth: CGFloat? = 860
  public var headingNumbering = false

  public init(colors: ThemeColors, codeTokens: [String: String]) {
    self.colors = colors
    self.codeTokens = codeTokens
  }

  public static let defaultLight = ThemeStyle(
    colors: ThemeColors(
      background: "#FFFFFF", text: "#333333", secondaryText: "#777777", heading: "#222222",
      link: "#4183C4", codeBackground: "#F6F8FA", codeText: "#24292E", quoteBar: "#DFE2E5",
      highlight: "#FFF59D", hr: "#E1E4E8", tableBorder: "#DFE2E5", tableHeader: "#F6F8FA",
      selection: "#B3D7FF", note: "#0969DA", tip: "#1A7F37", important: "#8250DF",
      warning: "#9A6700", caution: "#CF222E"),
    codeTokens: [
      "keyword": "#A626A4", "string": "#50A14F", "comment": "#A0A1A7", "number": "#986801",
      "function": "#4078F2", "function.call": "#4078F2", "type": "#C18401", "constant": "#986801",
      "variable.builtin": "#E45649", "property": "#E45649", "operator": "#383A42",
      "constructor": "#C18401", "attribute": "#986801", "tag": "#E45649", "boolean": "#986801",
    ])

  public static let defaultDark = ThemeStyle(
    colors: ThemeColors(
      background: "#1E1F22", text: "#D4D4D4", secondaryText: "#9DA3AD", heading: "#ECECEC",
      link: "#6CB6FF", codeBackground: "#2B2D31", codeText: "#D4D4D4", quoteBar: "#4A4D55",
      highlight: "#6B5B00", hr: "#3A3D44", tableBorder: "#4A4D55", tableHeader: "#2B2D31",
      selection: "#264F78", note: "#4493F8", tip: "#3FB950", important: "#AB7DF8",
      warning: "#D29922", caution: "#F85149"),
    codeTokens: [
      "keyword": "#C678DD", "string": "#98C379", "comment": "#7F848E", "number": "#D19A66",
      "function": "#61AFEF", "function.call": "#61AFEF", "type": "#E5C07B", "constant": "#D19A66",
      "variable.builtin": "#E06C75", "property": "#E06C75", "operator": "#ABB2BF",
      "constructor": "#E5C07B", "attribute": "#D19A66", "tag": "#E06C75", "boolean": "#D19A66",
    ])
}

public struct ThemeColors: Sendable, Equatable {
  public var background, text, secondaryText, heading, link, codeBackground, codeText,
    quoteBar: String
  public var highlight, hr, tableBorder, tableHeader, selection: String
  public var note, tip, important, warning, caution: String

  public init(
    background: String, text: String, secondaryText: String, heading: String, link: String,
    codeBackground: String, codeText: String, quoteBar: String, highlight: String, hr: String,
    tableBorder: String, tableHeader: String, selection: String, note: String, tip: String,
    important: String, warning: String, caution: String
  ) {
    self.background = background
    self.text = text
    self.secondaryText = secondaryText
    self.heading = heading
    self.link = link
    self.codeBackground = codeBackground
    self.codeText = codeText
    self.quoteBar = quoteBar
    self.highlight = highlight
    self.hr = hr
    self.tableBorder = tableBorder
    self.tableHeader = tableHeader
    self.selection = selection
    self.note = note
    self.tip = tip
    self.important = important
    self.warning = warning
    self.caution = caution
  }
}

/// A `ThemeStyle` turned into fonts and colours at a given zoom, cached per restyle.
@MainActor
final class ResolvedTheme {
  let style: ThemeStyle
  let zoom: CGFloat
  let isDark: Bool
  let body: NSFont
  let mono: NSFont
  let text, secondary, heading, link, codeBackground, codeText, quoteBar, highlight, hr: NSColor
  let background, tableBorder, tableHeader, selection: NSColor
  let tokenColors: [String: NSColor]
  private var fontCache: [String: NSFont] = [:]

  init(style: ThemeStyle, zoom: CGFloat, isDark: Bool) {
    self.style = style
    self.zoom = zoom
    self.isDark = isDark
    let size = style.baseSize * zoom
    body = style.bodyFont.flatMap { NSFont(name: $0, size: size) } ?? .systemFont(ofSize: size)
    mono =
      style.monoFont.flatMap { NSFont(name: $0, size: size * 0.9) }
      ?? .monospacedSystemFont(ofSize: size * 0.88, weight: .regular)
    let c = style.colors
    text = NSColor(hex: c.text)
    secondary = NSColor(hex: c.secondaryText)
    heading = NSColor(hex: c.heading)
    link = NSColor(hex: c.link)
    codeBackground = NSColor(hex: c.codeBackground)
    codeText = NSColor(hex: c.codeText)
    quoteBar = NSColor(hex: c.quoteBar)
    highlight = NSColor(hex: c.highlight)
    hr = NSColor(hex: c.hr)
    background = NSColor(hex: c.background)
    tableBorder = NSColor(hex: c.tableBorder)
    tableHeader = NSColor(hex: c.tableHeader)
    selection = NSColor(hex: c.selection)
    tokenColors = style.codeTokens.mapValues { NSColor(hex: $0) }
  }

  func calloutColor(_ t: CalloutType) -> NSColor {
    let c = style.colors
    switch t {
    case .note: return NSColor(hex: c.note)
    case .tip: return NSColor(hex: c.tip)
    case .important: return NSColor(hex: c.important)
    case .warning: return NSColor(hex: c.warning)
    case .caution: return NSColor(hex: c.caution)
    }
  }

  func headingFont(_ level: Int) -> NSFont {
    let scale = style.headingScales[max(0, min(5, level - 1))]
    return font(size: body.pointSize * scale, bold: true, italic: false)
  }

  /// Body-family font with traits, cached.
  func font(size: CGFloat? = nil, bold: Bool, italic: Bool, mono useMono: Bool = false) -> NSFont {
    let base = useMono ? mono : body
    let s = size ?? base.pointSize
    let key = "\(s)-\(bold)-\(italic)-\(useMono)"
    if let f = fontCache[key] { return f }
    var traits: NSFontDescriptor.SymbolicTraits = []
    if bold { traits.insert(.bold) }
    if italic { traits.insert(.italic) }
    let d = base.fontDescriptor.withSymbolicTraits(traits)
    let f = NSFont(descriptor: d, size: s) ?? base
    fontCache[key] = f
    return f
  }
}

extension NSColor {
  /// `#RGB`, `#RRGGBB` or `#RRGGBBAA`; unknown strings fall back to the label colour.
  convenience init(hex: String) {
    var s = hex.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
    var v: UInt64 = 0
    guard Scanner(string: s).scanHexInt64(&v), s.count == 6 || s.count == 8 else {
      if let named = NSColor.cssNamed[hex.lowercased()] {
        self.init(srgbRed: named.0, green: named.1, blue: named.2, alpha: 1)
      } else {
        self.init(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
      }
      return
    }
    if s.count == 6 { v = (v << 8) | 0xFF }
    self.init(
      srgbRed: CGFloat((v >> 24) & 0xFF) / 255, green: CGFloat((v >> 16) & 0xFF) / 255,
      blue: CGFloat((v >> 8) & 0xFF) / 255, alpha: CGFloat(v & 0xFF) / 255)
  }

  static let cssNamed: [String: (CGFloat, CGFloat, CGFloat)] = [
    "red": (1, 0, 0), "green": (0, 0.5, 0), "blue": (0, 0, 1), "black": (0, 0, 0),
    "white": (1, 1, 1),
    "gray": (0.5, 0.5, 0.5), "grey": (0.5, 0.5, 0.5), "orange": (1, 0.65, 0), "yellow": (1, 1, 0),
    "purple": (0.5, 0, 0.5), "pink": (1, 0.75, 0.8), "brown": (0.65, 0.16, 0.16), "cyan": (0, 1, 1),
    "magenta": (1, 0, 1), "teal": (0, 0.5, 0.5), "navy": (0, 0, 0.5), "olive": (0.5, 0.5, 0),
    "maroon": (0.5, 0, 0), "lime": (0, 1, 0), "silver": (0.75, 0.75, 0.75), "gold": (1, 0.84, 0),
  ]
}
