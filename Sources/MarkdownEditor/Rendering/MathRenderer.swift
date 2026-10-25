import AppKit
import SwiftMath

/// Document-wide math state: user macros (in document order) and `\label` → number.
struct MathContext {
  var macros: [String: MathPreprocessor.Macro] = [:]
  var numbers: [Int: String] = [:]  // math block start → equation number
  var labels: [String: String] = [:]  // label → equation number

  @MainActor static func build(
    _ model: DocumentModel, text: NSString, numbering: EditorPreferences.MathNumbering
  ) -> MathContext {
    var ctx = MathContext()
    var n = 0
    for (b, off) in model.blocks(where: { $0 == .math }) {
      let latex = b.content.map { text.substring(with: $0.shifted(by: off)) } ?? ""
      MathPreprocessor.collectMacros(latex, into: &ctx.macros)
      let tagged = MathPreprocessor.tag(in: latex)
      let numbered =
        latex.contains("\\notag") || latex.contains("\\nonumber")
        ? false
        : tagged != nil || numbering == .all
          || (numbering == .ams
            && latex.range(
              of: #"\\begin\{(equation|align|gather|multline)\}"#, options: .regularExpression)
              != nil)
      guard numbered else { continue }
      let number: String
      if let tagged {
        number = tagged
      } else {
        n += 1
        number = "\(n)"
      }
      ctx.numbers[off + b.range.location] = number
      if let label = latex.firstMatch(of: #/\\label\{([^}]*)\}/#) {
        ctx.labels[String(label.1)] = number
      }
    }
    return ctx
  }
}

/// Turns Typora/MathJax LaTeX into what SwiftMath typesets. Pure.
///
/// Not supported (published in the README): `\middle` (dropped), `\:` `\;` `\!` (approximated),
/// `\ce` beyond formulas/charges/arrows/coefficients, `\href`, `\class`, `\bbox`, `\unicode`,
/// and environments SwiftMath lacks (`gather`, `multline`, `CD`, `array` with rules).
enum MathPreprocessor {
  struct Macro: Equatable {
    var args: Int
    var body: String
  }

  static func tag(in latex: String) -> String? {
    latex.firstMatch(of: #/\\tag\*?\{([^}]*)\}/#).map { String($0.1) }
  }

  /// `\newcommand{\R}{\mathbb{R}}`, `\newcommand\f[2]{…}`, `\def\x#1{…}`.
  static func collectMacros(_ latex: String, into macros: inout [String: Macro]) {
    for m in latex.matches(
      of: #/\\(?:re)?newcommand\*?\s*\{?\\([A-Za-z]+)\}?\s*(?:\[(\d)\])?\s*\{/#)
    {
      if let body = braceGroup(latex, from: m.range.upperBound) {
        macros[String(m.1)] = Macro(args: Int(m.2 ?? "0") ?? 0, body: body.content)
      }
    }
    for m in latex.matches(of: #/\\def\s*\\([A-Za-z]+)((?:#\d)*)\s*\{/#) {
      if let body = braceGroup(latex, from: m.range.upperBound) {
        macros[String(m.1)] = Macro(args: m.2.count / 2, body: body.content)
      }
    }
  }

  /// The `{…}` group whose opening brace is just before `from`.
  static func braceGroup(_ s: String, from: String.Index) -> (content: String, end: String.Index)? {
    var depth = 1
    var i = from
    while i < s.endIndex {
      let c = s[i]
      if c == "\\" {
        i = s.index(after: i)
        if i < s.endIndex { i = s.index(after: i) }
        continue
      }
      if c == "{" { depth += 1 }
      if c == "}" {
        depth -= 1
        if depth == 0 { return (String(s[from..<i]), s.index(after: i)) }
      }
      i = s.index(after: i)
    }
    return nil
  }

  static func prepare(_ latex: String, context: MathContext, physics: Bool) -> String {
    var s = latex
    // Definitions render as nothing.
    s = s.replacingOccurrences(
      of: #"\\(?:re)?newcommand\*?\s*\{?\\[A-Za-z]+\}?\s*(?:\[\d\])?\s*\{(?:[^{}]|\{[^{}]*\})*\}"#,
      with: "", options: .regularExpression)
    s = s.replacingOccurrences(
      of: #"\\def\s*\\[A-Za-z]+(?:#\d)*\s*\{(?:[^{}]|\{[^{}]*\})*\}"#, with: "",
      options: .regularExpression)
    s = s.replacingOccurrences(
      of: #"\\(?:tag\*?|label)\{[^}]*\}|\\notag|\\nonumber"#, with: "", options: .regularExpression)
    s = resolveRefs(s, labels: context.labels)
    var macros = context.macros
    if physics { macros.merge(physicsMacros) { a, _ in a } }
    s = expand(s, macros: macros)
    s = chemistry(s)
    // Environments and spacing SwiftMath doesn't know.
    let rules: [(String, String)] = [
      (#"\\begin\{(?:equation|displaymath)\*?\}"#, ""),
      (#"\\end\{(?:equation|displaymath)\*?\}"#, ""),
      (#"\\begin\{(?:align|gather|multline|alignat)\*?\}(?:\{\d+\})?"#, "\\\\begin{aligned}"),
      (#"\\end\{(?:align|gather|multline|alignat)\*?\}"#, "\\\\end{aligned}"),
      (#"\\(?:[:>])"#, "\\\\,\\\\,"), (#"\\;"#, "\\\\,\\\\,\\\\,"), (#"\\!"#, ""),
      (#"\\middle\s*"#, ""), (#"\\(?:dfrac)"#, "\\\\frac"),
    ]
    for (p, r) in rules { s = s.replacingOccurrences(of: p, with: r, options: .regularExpression) }
    if let m = s.firstMatch(of: #/\\displaylines\{/#),
      let g = braceGroup(s, from: m.range.upperBound)
    {
      s.replaceSubrange(
        m.range.lowerBound..<g.end, with: "\\begin{aligned}\(g.content)\\end{aligned}")
    }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func resolveRefs(_ s: String, labels: [String: String]) -> String {
    var out = s
    for m in s.matches(of: #/\\(eq)?ref\{([^}]*)\}/#).reversed() {
      let n = labels[String(m.2)] ?? "??"
      out.replaceSubrange(m.range, with: m.1 != nil ? "\\text{(\(n))}" : "\\text{\(n)}")
    }
    return out
  }

  /// Expand user (and physics) macros, arguments taken from `{…}` groups.
  static func expand(_ s: String, macros: [String: Macro], depth: Int = 0) -> String {
    guard !macros.isEmpty, depth < 8, s.contains("\\") else { return s }
    var out = ""
    var i = s.startIndex
    var changed = false
    while i < s.endIndex {
      guard s[i] == "\\" else {
        out.append(s[i])
        i = s.index(after: i)
        continue
      }
      var j = s.index(after: i)
      while j < s.endIndex, s[j].isLetter { j = s.index(after: j) }
      let name = String(s[s.index(after: i)..<j])
      guard let m = macros[name], !name.isEmpty else {
        out += s[i..<max(j, s.index(after: i))]
        i = max(j, s.index(after: i))
        continue
      }
      var body = m.body
      var k = j
      for n in 1...max(1, m.args) where m.args > 0 {
        while k < s.endIndex, s[k] == " " { k = s.index(after: k) }
        if k < s.endIndex, s[k] == "{", let g = braceGroup(s, from: s.index(after: k)) {
          body = body.replacingOccurrences(of: "#\(n)", with: g.content)
          k = g.end
        } else if k < s.endIndex {
          body = body.replacingOccurrences(of: "#\(n)", with: String(s[k]))
          k = s.index(after: k)
        }
      }
      out += "{\(body)}"
      i = k
      changed = true
    }
    return changed ? expand(out, macros: macros, depth: depth + 1) : out
  }

  static let physicsMacros: [String: Macro] = [
    "abs": Macro(args: 1, body: "\\left| #1 \\right|"),
    "norm": Macro(args: 1, body: "\\left\\| #1 \\right\\|"),
    "dv": Macro(args: 2, body: "\\frac{d #1}{d #2}"),
    "pdv": Macro(args: 2, body: "\\frac{\\partial #1}{\\partial #2}"),
    "bra": Macro(args: 1, body: "\\left\\langle #1 \\right|"),
    "ket": Macro(args: 1, body: "\\left| #1 \\right\\rangle"),
    "braket": Macro(args: 2, body: "\\left\\langle #1 | #2 \\right\\rangle"),
    "expval": Macro(args: 1, body: "\\left\\langle #1 \\right\\rangle"),
    "qty": Macro(args: 1, body: "\\left( #1 \\right)"),
    "vb": Macro(args: 1, body: "\\mathbf{#1}"),
    "grad": Macro(args: 0, body: "\\nabla"),
    "curl": Macro(args: 0, body: "\\nabla\\times"),
    "order": Macro(args: 1, body: "\\mathcal{O}\\left( #1 \\right)"),
  ]

  /// `\ce{2H2 + O2 -> 2H2O}` subset: formulas, charges, arrows and coefficients.
  static func chemistry(_ s: String) -> String {
    var out = s
    while let m = out.firstMatch(of: #/\\ce\s*\{/#),
      let g = braceGroup(out, from: m.range.upperBound)
    {
      var c = g.content
      let rules: [(String, String)] = [
        ("<=>", "\\\\rightleftharpoons "), ("->", "\\\\rightarrow "), ("<-", "\\\\leftarrow "),
        (#"([A-Za-z\)\]])(\d+)"#, "$1_{$2}"), (#"\^(\d*[+-])"#, "^{$1}"),
        (#"([A-Za-z\)\]])([+-])(?=\s|$|\})"#, "$1^{$2}"),
      ]
      for (p, r) in rules {
        c = c.replacingOccurrences(of: p, with: r, options: .regularExpression)
      }
      out.replaceSubrange(m.range.lowerBound..<g.end, with: "\\mathrm{\(c)}")
    }
    return out
  }
}

/// SwiftMath typesetting into an image with its baseline.
@MainActor
enum MathRenderer {
  static func render(latex: String, display: Bool, dark: Bool, fontSize: CGFloat, number: String?)
    -> RenderResult
  {
    let label = MTMathUILabel()
    label.displayErrorInline = false
    label.labelMode = display ? .display : .text
    label.fontSize = fontSize
    label.textColor = dark ? NSColor(white: 0.9, alpha: 1) : NSColor(white: 0.12, alpha: 1)
    var source = latex
    if display, let number { source += "\\qquad\\text{(\(number))}" }
    label.latex = source.isEmpty ? "\\," : source
    if let e = label.error {
      return RenderResult(image: nil, size: .zero, error: e.localizedDescription)
    }
    let size = label.fittingSize
    label.frame = CGRect(origin: .zero, size: size)
    label.layout()
    guard let list = label.displayList, size.width > 0 else {
      return RenderResult(image: nil, size: .zero, error: "Could not typeset")
    }
    // The label lays the list out itself (position is internal); draw it into a 2x bitmap.
    guard
      let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * 2)),
        pixelsHigh: Int(ceil(size.height * 2)),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)
    else { return RenderResult(image: nil, size: .zero, error: "Could not typeset") }
    rep.size = size
    label.cacheDisplay(in: label.bounds, to: rep)
    let image = NSImage(size: size)
    image.addRepresentation(rep)
    let imageSize = size
    // The label centres the list vertically; its baseline sits `descent` above the bottom.
    return RenderResult(
      image: image, size: imageSize,
      descent: (size.height - list.ascent - list.descent) / 2 + list.descent)
  }
}
