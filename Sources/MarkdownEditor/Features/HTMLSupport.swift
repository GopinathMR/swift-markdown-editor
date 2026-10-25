import AppKit
import SwiftSoup
import Yams

/// Strip everything that could run or reach out: scripts, styles, handlers, `javascript:`.
enum HTMLSanitizer {
  static let dropped =
    "script, style, meta, link, base, object, embed, iframe, frame, frameset, form, input, button, textarea, select"

  static func sanitize(_ html: String) -> String {
    guard let doc = try? SwiftSoup.parseBodyFragment(html) else { return "" }
    try? doc.select(dropped).remove()
    for el in (try? doc.getAllElements().array()) ?? [] {
      for attr in el.getAttributes()?.asList() ?? [] {
        let key = attr.getKey().lowercased()
        let value = attr.getValue().trimmingCharacters(in: .whitespaces).lowercased()
        if key.hasPrefix("on")
          || ((key == "href" || key == "src" || key == "action") && value.hasPrefix("javascript:"))
        {
          try? el.removeAttr(attr.getKey())
        }
      }
      // Remote images would load synchronously during HTML import; keep their alt text.
      if el.tagName() == "img", let src = try? el.attr("src"), src.hasPrefix("http") {
        try? el.replaceWith(TextNode((try? el.attr("alt")) ?? "", nil))
      }
    }
    return (try? doc.body()?.html()) ?? ""
  }

  /// True when nothing would be visible (only scripts, styles, metas, comments).
  static func isInvisible(_ html: String) -> Bool {
    guard let doc = try? SwiftSoup.parseBodyFragment(html) else { return true }
    try? doc.select(dropped).remove()
    let text = (try? doc.body()?.text()) ?? ""
    let media = (try? doc.select("img, svg, video, audio, hr, table").isEmpty()) == false
    return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !media
  }
}

/// Block HTML → image, through AppKit's HTML import (no script runs there).
@MainActor
enum HTMLBlockRenderer {
  static func render(_ html: String, width: CGFloat, dark: Bool) -> RenderResult {
    guard !HTMLSanitizer.isInvisible(html) else {
      return RenderResult(image: nil, size: .zero)
    }
    let color = dark ? "#D4D4D4" : "#333333"
    let page =
      "<div style=\"font-family:-apple-system,Helvetica;font-size:16px;color:\(color)\">\(HTMLSanitizer.sanitize(html))</div>"
    guard
      let attr = try? NSAttributedString(
        data: Data(page.utf8),
        options: [
          .documentType: NSAttributedString.DocumentType.html,
          .characterEncoding: String.Encoding.utf8.rawValue,
        ],
        documentAttributes: nil)
    else { return RenderResult(image: nil, size: .zero, error: "Could not render HTML") }
    let bounds = attr.boundingRect(
      with: CGSize(width: width, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading])
    let size = CGSize(width: ceil(min(width, bounds.width)) + 2, height: ceil(bounds.height) + 2)
    let image = NSImage(size: size, flipped: true) { _ in
      attr.draw(
        with: CGRect(origin: .zero, size: CGSize(width: width, height: size.height)),
        options: [.usesLineFragmentOrigin, .usesFontLeading])
      return true
    }
    return RenderResult(image: image, size: size)
  }
}

/// Clipboard HTML → markdown (paste from browsers, Pages, Word …).
enum HTMLToMarkdown {
  static func convert(_ html: String) -> String {
    guard let doc = try? SwiftSoup.parse(html), let body = doc.body() else { return "" }
    var out = blocks(body.getChildNodes(), listDepth: 0)
    while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
    return out.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func blocks(_ nodes: [SwiftSoup.Node], listDepth: Int) -> String {
    var out = ""
    var inlineRun = ""
    func flush() {
      let t = inlineRun.trimmingCharacters(in: .whitespacesAndNewlines)
      if !t.isEmpty { out += t + "\n\n" }
      inlineRun = ""
    }
    for node in nodes {
      guard let el = node as? Element else {
        inlineRun += inline([node])
        continue
      }
      let tag = el.tagName().lowercased()
      switch tag {
      case "h1", "h2", "h3", "h4", "h5", "h6":
        flush()
        out +=
          String(repeating: "#", count: Int(String(tag.last!))!) + " "
          + inline(el.getChildNodes()).trimmingCharacters(in: .whitespaces) + "\n\n"
      case "p", "div", "section", "article", "header", "footer", "main", "figure", "figcaption":
        flush()
        let inner = el.children().array().contains { blockTags.contains($0.tagName().lowercased()) }
        out +=
          inner
          ? blocks(el.getChildNodes(), listDepth: listDepth)
          : inline(el.getChildNodes()).trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
      case "ul", "ol":
        flush()
        out += list(el, ordered: tag == "ol", depth: listDepth) + "\n"
      case "blockquote":
        flush()
        let inner = blocks(el.getChildNodes(), listDepth: listDepth).trimmingCharacters(
          in: .whitespacesAndNewlines)
        out +=
          inner.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }.joined(
            separator: "\n") + "\n\n"
      case "pre":
        flush()
        let code = (try? el.text(trimAndNormaliseWhitespace: false)) ?? ""
        let cls = (try? el.select("code").first()?.className()) ?? ""
        let lang =
          cls.components(separatedBy: " ").first { $0.hasPrefix("language-") }.map {
            String($0.dropFirst(9))
          } ?? ""
        out += "```\(lang)\n" + code.trimmingCharacters(in: .newlines) + "\n```\n\n"
      case "hr":
        flush()
        out += "---\n\n"
      case "table":
        flush()
        out += table(el) + "\n\n"
      case "br":
        inlineRun += "\n"
      case "script", "style", "meta", "head", "title":
        continue
      default:
        inlineRun += inline([el])
      }
    }
    flush()
    return out
  }

  private static let blockTags: Set<String> = [
    "p", "div", "ul", "ol", "table", "pre", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6", "hr",
    "section",
  ]

  private static func list(_ el: Element, ordered: Bool, depth: Int) -> String {
    var lines: [String] = []
    var n = Int((try? el.attr("start")) ?? "") ?? 1
    for li in el.children().array() where li.tagName().lowercased() == "li" {
      let marker = ordered ? "\(n). " : "- "
      n += 1
      let indent = String(repeating: " ", count: depth * (ordered ? 3 : 2))
      var text = ""
      var nested = ""
      for child in li.getChildNodes() {
        if let c = child as? Element, ["ul", "ol"].contains(c.tagName().lowercased()) {
          nested += list(c, ordered: c.tagName().lowercased() == "ol", depth: depth + 1)
        } else if let c = child as? Element, c.tagName().lowercased() == "p" {
          text += inline(c.getChildNodes())
        } else {
          text += inline([child])
        }
      }
      if let box = try? li.select("input[type=checkbox]").first() {
        text = (box.hasAttr("checked") ? "[x] " : "[ ] ") + text
      }
      lines.append(indent + marker + text.trimmingCharacters(in: .whitespacesAndNewlines))
      if !nested.isEmpty { lines.append(nested.trimmingCharacters(in: .newlines)) }
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private static func table(_ el: Element) -> String {
    let rows = ((try? el.select("tr").array()) ?? []).map { tr in
      ((try? tr.select("th, td").array()) ?? []).map {
        inline($0.getChildNodes()).trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }.filter { !$0.isEmpty }
    guard let header = rows.first else { return "" }
    return TableModel(
      header: header, rows: Array(rows.dropFirst()), alignments: header.map { _ in .none }
    ).serialized()
  }

  private static func inline(_ nodes: [SwiftSoup.Node]) -> String {
    var out = ""
    for node in nodes {
      if let t = node as? TextNode {
        out += t.text().replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        continue
      }
      guard let el = node as? Element else { continue }
      let inner = inline(el.getChildNodes())
      func wrap(_ m: String) -> String {
        let t = inner.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? inner : m + t + m
      }
      switch el.tagName().lowercased() {
      case "strong", "b": out += wrap("**")
      case "em", "i": out += wrap("*")
      case "del", "s", "strike": out += wrap("~~")
      case "code", "kbd", "tt": out += "`" + ((try? el.text()) ?? "") + "`"
      case "mark": out += wrap("==")
      case "u", "ins": out += "<u>\(inner)</u>"
      case "sup": out += "<sup>\(inner)</sup>"
      case "sub": out += "<sub>\(inner)</sub>"
      case "a":
        let href = (try? el.attr("href")) ?? ""
        out +=
          href.isEmpty || href.hasPrefix("javascript:")
          ? inner : "[\(inner.trimmingCharacters(in: .whitespaces))](\(href))"
      case "img":
        let src = (try? el.attr("src")) ?? ""
        if !src.isEmpty { out += "![\((try? el.attr("alt")) ?? "")](\(src))" }
      case "br": out += "\n"
      case "script", "style": continue
      default: out += inner
      }
    }
    return out
  }
}

/// YAML front matter values (`typora-*` keys, export overrides) and validity.
enum FrontMatter {
  struct Parsed {
    var values: [String: Any]
    var error: String?
  }

  nonisolated(unsafe) private static var cache: (String, Parsed)?

  /// `block` is the whole `---` … `---` block.
  static func parse(_ block: String) -> Parsed {
    if let c = cache, c.0 == block { return c.1 }
    var lines = block.components(separatedBy: .newlines)
    if lines.first?.trimmingCharacters(in: .whitespaces) == "---" { lines.removeFirst() }
    while let last = lines.last,
      last.trimmingCharacters(in: .whitespaces).isEmpty
        || ["---", "..."].contains(last.trimmingCharacters(in: .whitespaces))
    {
      lines.removeLast()
    }
    let yaml = lines.joined(separator: "\n")
    let parsed: Parsed
    do {
      let v = try Yams.load(yaml: yaml)
      parsed = Parsed(
        values: v as? [String: Any] ?? [:],
        error: v == nil || v is [String: Any] ? nil : "Front matter should be a mapping")
    } catch {
      parsed = Parsed(
        values: [:], error: "\(error)".components(separatedBy: "\n").first ?? "Invalid YAML")
    }
    cache = (block, parsed)
    return parsed
  }

  /// Dotted lookup: `author`, `export.title`.
  static func value(_ key: String, in values: [String: Any]) -> String? {
    var cur: Any? = values
    for part in key.split(separator: ".") { cur = (cur as? [String: Any])?[String(part)] }
    switch cur {
    case let s as String: return s
    case let n as NSNumber: return n.stringValue
    case let a as [Any]: return a.map { "\($0)" }.joined(separator: ", ")
    default: return cur.map { "\($0)" }
    }
  }
}
