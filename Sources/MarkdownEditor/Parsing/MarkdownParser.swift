import CodeEditLanguages
import Foundation
import SwiftTreeSitter

/// tree-sitter markdown (block + inline) → `DocumentModel`.
///
/// Top-level blocks are context-free values with ranges relative to their own start. An edit
/// reparses only a window of top-level blocks around it and splices the result in; a full
/// parse (opening a file) builds blocks in parallel. tree-sitter's own incremental reparse
/// re-lexes the whole document for markdown with lists, code or math (measured: ~250 ms on
/// 1.9 MB), so it isn't used.
@MainActor
final class MarkdownParser {
  var preferences: EditorPreferences {
    didSet {
      if preferences != oldValue {
        cache.removeAll()
        builder = BlockBuilder(preferences: preferences)
      }
    }
  }

  private let blockParser = Parser()
  private var builder: BlockBuilder
  private var cache: [String: Block] = [:]
  private var previous: [BlockEntry] = []

  init(preferences: EditorPreferences) {
    self.preferences = preferences
    builder = BlockBuilder(preferences: preferences)
    // The grammar is compiled into CodeEditLanguages; failure here is a packaging bug.
    try! blockParser.setLanguage(CodeLanguage.markdown.language!)
  }

  struct Result {
    var model: DocumentModel
    /// Indices of entries that are new or changed since the previous result.
    var changed: IndexSet
  }

  /// Parse everything. Inline parsing dominates, and blocks are independent: fan out.
  func parse(_ text: NSString) -> Result {
    let nodes = topLevelNodes(text)
    let count = nodes.count
    var blocks = [Block?](repeating: nil, count: count)
    var keys = [String](repeating: "", count: count)
    let prefs = preferences
    let cacheSnapshot = cache
    let input = UncheckedBox((nodes, text))
    let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, count / 32 + 1))
    blocks.withUnsafeMutableBufferPointer { blockBuf in
      keys.withUnsafeMutableBufferPointer { keyBuf in
        let out = UncheckedBox((blockBuf, keyBuf))
        DispatchQueue.concurrentPerform(iterations: workers) { w in
          let builder = BlockBuilder(preferences: prefs)
          let (nodes, text) = input.value
          var i = w
          while i < nodes.count {
            let r = nodes[i].range
            // Same text can parse as another node type elsewhere; key on both.
            let key = (nodes[i].nodeType ?? "") + "\u{0}" + text.substring(with: r)
            out.value.1[i] = key
            out.value.0[i] =
              cacheSnapshot[key] ?? builder.makeBlock(nodes[i], base: r.location, text: text)
            i += workers
          }
        }
      }
    }
    var entries: [BlockEntry] = []
    entries.reserveCapacity(count)
    var newCache: [String: Block] = [:]
    for i in 0..<count {
      let r = nodes[i].range
      let block =
        blocks[i] ?? Block(kind: .paragraph, range: NSRange(location: 0, length: r.length))
      newCache[keys[i]] = block
      entries.append(BlockEntry(start: r.location, block: block))
    }
    cache = newCache
    previous = entries
    return finish(entries, changed: IndexSet(integersIn: 0..<entries.count), text: text)
  }

  /// `editedRange` is in the new text; `delta` is the change in length.
  func update(_ text: NSString, editedRange: NSRange, delta: Int) -> Result {
    guard !previous.isEmpty else { return parse(text) }
    let count = previous.count
    let oldLength = text.length - delta
    let first = previous.firstIndex { $0.range.end >= editedRange.location } ?? count - 1
    let last = previous.lastIndex { $0.start <= editedRange.end - delta } ?? 0
    var lo = max(0, min(first, last) - 1)
    var hi = min(count - 1, max(first, last) + 1)
    // Reparse lo...hi plus one untouched "probe" entry each side. The window is right when
    // both probes come back unchanged; otherwise a neighbour joined in, so widen and retry.
    for _ in 0..<12 {
      let before = lo > 0 ? lo - 1 : nil
      let after = hi + 1 < count ? hi + 1 : nil
      let start = before.map { previous[$0].start } ?? 0
      let endOld = after.map { $0 + 1 < count ? previous[$0 + 1].start : oldLength } ?? oldLength
      guard var parsed = parseWindow(text, NSRange(location: start, length: endOld + delta - start))
      else { break }
      // An unclosed fence or comment runs to the end of the document: take everything.
      if after != nil,
        parsed.contains(where: { Self.swallowsRest($0.block, text: text, offset: $0.start) })
      {
        hi = count - 1
        continue
      }
      var okBefore = true
      var okAfter = true
      if let b = before {
        okBefore =
          parsed.first.map { $0.start == previous[b].start && $0.length == previous[b].length }
          ?? false
        if okBefore { parsed.removeFirst() }
      }
      if let a = after {
        okAfter =
          parsed.last.map {
            $0.start == previous[a].start + delta && $0.length == previous[a].length
          } ?? false
        if okAfter { parsed.removeLast() }
      }
      if okBefore && okAfter {
        var entries = Array(previous[..<lo])
        entries.reserveCapacity(count + parsed.count)
        let changed = IndexSet(integersIn: entries.count..<(entries.count + parsed.count))
        entries += parsed
        for e in previous[(hi + 1)...] {
          entries.append(BlockEntry(start: e.start + delta, block: e.block))
        }
        previous = entries
        return finish(entries, changed: changed, text: text)
      }
      if !okBefore { lo = max(0, lo - 1) }
      if !okAfter { hi = min(count - 1, hi + 1) }
    }
    return parse(text)
  }

  private func parseWindow(_ text: NSString, _ window: NSRange) -> [BlockEntry]? {
    guard window.length >= 0, window.end <= text.length else { return nil }
    let sub = text.substring(with: window) as NSString
    var out: [BlockEntry] = []
    for node in topLevelNodes(sub) {
      let r = node.range
      let key = (node.nodeType ?? "") + "\u{0}" + sub.substring(with: r)
      let block =
        cache[key] ?? builder.makeBlock(node, base: r.location, text: sub)
        ?? Block(kind: .paragraph, range: NSRange(location: 0, length: r.length))
      cache[key] = block
      out.append(BlockEntry(start: window.location + r.location, block: block))
    }
    if cache.count > previous.count * 2 + 1024 { cache.removeAll() }
    return out
  }

  private static func swallowsRest(_ b: Block, text: NSString, offset: Int) -> Bool {
    switch b.kind {
    case .code, .diagram: return b.markers.count == 1
    case .comment: return !text.substring(with: b.range.shifted(by: offset)).contains("-->")
    default: return false
    }
  }

  private func topLevelNodes(_ text: NSString) -> [Node] {
    guard let tree = blockParser.parse(tree: nil as Tree?, readBlock: Self.reader(text)),
      let root = tree.rootNode
    else { return [] }
    var nodes: [Node] = []
    func collect(_ node: Node) {
      node.enumerateChildren { child in
        if child.nodeType == "section" {
          collect(child)
        } else if child.range.length > 0 {
          nodes.append(child)
        }
      }
    }
    collect(root)
    return nodes
  }

  private func finish(_ entries: [BlockEntry], changed: IndexSet, text: NSString) -> Result {
    var model = DocumentModel(entries: entries)
    finishModel(&model, text: text)
    return Result(model: model, changed: changed)
  }

  private static func reader(_ text: NSString) -> Parser.ReadBlock {
    let length = text.length
    return { byteOffset, _ in
      let start = byteOffset / 2
      guard start < length else { return nil }
      let count = min(8192, length - start)
      var buffer = [unichar](repeating: 0, count: count)
      text.getCharacters(&buffer, range: NSRange(location: start, length: count))
      return buffer.withUnsafeBytes { Data($0) }
    }
  }

  // MARK: Document-wide

  private func finishModel(_ model: inout DocumentModel, text: NSString) {
    var slugCounts: [String: Int] = [:]
    var counters = [Int](repeating: 0, count: 7)
    var footnoteOrder: [String: Int] = [:]
    for e in model.entries {
      let b = e.block
      switch b.kind {
      case .heading(let level), .setextHeading(let level):
        let title = visibleText(of: b, offset: e.start, text: text)
        var slug = HeadingInfo.slug(title)
        if let n = slugCounts[slug] {
          slugCounts[slug] = n + 1
          slug += "-\(n)"
        } else {
          slugCounts[slug] = 1
        }
        counters[level] += 1
        for l in (level + 1)..<7 { counters[l] = 0 }
        let top = counters[1...level].firstIndex { $0 > 0 } ?? level
        let number = counters[top...level].map(String.init).joined(separator: ".")
        model.headings.append(
          HeadingInfo(level: level, title: title, slug: slug, range: e.range, number: number))
      case .linkReferenceDefinition:
        if let parts = b.info?.split(
          separator: "\u{0}", maxSplits: 1, omittingEmptySubsequences: false), parts.count == 2
        {
          model.linkRefs[String(parts[0])] = String(parts[1])
        }
      case .footnoteDefinition(let id):
        model.footnoteDefinitions[id] = e.range
      case .frontMatter:
        model.frontMatter = b.info
      default: break
      }
      forEachInline(b) { i in
        if case .footnoteRef(let id) = i.kind, footnoteOrder[id] == nil {
          footnoteOrder[id] = footnoteOrder.count + 1
        }
      }
    }
    model.footnoteNumbers = footnoteOrder
  }

  func visibleText(of b: Block, offset: Int, text: NSString) -> String {
    let start = b.markers.first.map { $0.end } ?? b.range.location
    var r = NSRange(location: start, length: b.range.end - start)
    if case .setextHeading = b.kind, let u = b.markers.first {
      r = NSRange(location: b.range.location, length: u.location - b.range.location)
    }
    let s = NSMutableString(string: text.substring(with: r.shifted(by: offset)))
    var hidden: [NSRange] = []
    func collect(_ list: [Inline]) {
      for i in list {
        hidden.append(contentsOf: i.markers)
        collect(i.children)
      }
    }
    collect(b.inlines)
    for h in hidden.sorted(by: { $0.location > $1.location }) {
      let local = h.shifted(by: -r.location)
      if local.location >= 0, local.end <= s.length { s.deleteCharacters(in: local) }
    }
    return (s as String).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// Builds context-free blocks (and their inlines) from tree-sitter nodes. Not thread-safe:
/// one per thread, since it owns an inline parser.
final class BlockBuilder: @unchecked Sendable {
  let preferences: EditorPreferences
  private let inlineParser = Parser()

  init(preferences: EditorPreferences) {
    self.preferences = preferences
    try! inlineParser.setLanguage(CodeLanguage.markdownInline.language!)
  }

  // MARK: Blocks

  func makeBlock(_ node: Node, base: Int, text: NSString) -> Block? {
    let r = node.range
    let rel = NSRange(location: r.location - base, length: r.length)
    func relr(_ n: Node) -> NSRange {
      NSRange(location: n.range.location - base, length: n.range.length)
    }
    func kids() -> [Node] {
      var a: [Node] = []
      node.enumerateChildren { a.append($0) }
      return a
    }
    switch node.nodeType {
    case "atx_heading":
      var b = Block(kind: .heading(1), range: rel)
      for c in kids() {
        let t = c.nodeType ?? ""
        if t.hasPrefix("atx_h"), t.hasSuffix("_marker"),
          let lvl = Int(String(t.dropFirst(5).prefix(1)))
        {
          b.kind = .heading(lvl)
          b.markers.append(relr(c))
        } else if t == "inline" {
          // Hide the gap between `#` and the text too.
          if let m = b.markers.last, c.range.location - base > m.end {
            b.markers[b.markers.count - 1] = NSRange(
              location: m.location, length: c.range.location - base - m.location)
          }
          b.inlines = inlines(of: c, base: base, text: text)
        }
      }
      return b

    case "setext_heading":
      var b = Block(kind: .setextHeading(1), range: rel)
      for c in kids() {
        switch c.nodeType {
        case "paragraph":
          c.enumerateChildren { i in
            if i.nodeType == "inline" { b.inlines = self.inlines(of: i, base: base, text: text) }
          }
        case "setext_h1_underline":
          b.kind = .setextHeading(1)
          b.markers.append(lineIncludingPrecedingNewline(relr(c), base: base, text: text))
        case "setext_h2_underline":
          b.kind = .setextHeading(2)
          b.markers.append(lineIncludingPrecedingNewline(relr(c), base: base, text: text))
        default: break
        }
      }
      return b

    case "paragraph":
      var b = Block(kind: .paragraph, range: rel)
      var inlineNode: Node?
      for c in kids() where c.nodeType == "inline" { inlineNode = c }
      if let i = inlineNode { b.inlines = inlines(of: i, base: base, text: text) }
      classifyParagraph(&b, base: base, text: text)
      return b

    case "block_quote":
      var b = Block(kind: .blockquote, range: rel)
      collectQuoteMarkers(node, base: base, text: text, into: &b.markers)
      for c in kids() {
        if let child = makeBlock(c, base: base, text: text), c.nodeType != "block_quote_marker",
          c.nodeType != "block_continuation"
        {
          b.children.append(child)
        }
      }
      // `> [!NOTE]` as the first line makes a callout.
      if let first = b.children.first, first.kind == .paragraph {
        let s = text.substring(with: first.range.shifted(by: base))
        if let m = s.firstMatch(of: #/^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]/#.ignoresCase()),
          let type = CalloutType(rawValue: String(m.1).uppercased())
        {
          b.kind = .callout(type)
          b.content = NSRange(location: first.range.location, length: m.0.utf16.count)
          b.children[0].inlines.removeAll {
            $0.range.location < first.range.location + m.0.utf16.count
          }
        }
      }
      return b

    case "list":
      var b = Block(kind: .list, range: rel)
      for c in kids() {
        if let child = makeBlock(c, base: base, text: text) { b.children.append(child) }
      }
      return b

    case "list_item":
      var b = Block(kind: .listItem(ordered: false, task: nil), range: rel)
      var ordered = false
      var task: Bool?
      for c in kids() {
        let t = c.nodeType ?? ""
        if t.hasPrefix("list_marker") {
          ordered = t == "list_marker_dot" || t == "list_marker_parenthesis"
          b.listMarker = relr(c)
          b.info = text.substring(with: c.range).trimmingCharacters(in: .whitespaces)
        } else if t == "task_list_marker_checked" || t == "task_list_marker_unchecked" {
          task = t == "task_list_marker_checked"
          b.taskMarker = relr(c)
        } else if t != "block_continuation", let child = makeBlock(c, base: base, text: text) {
          b.children.append(child)
        }
      }
      b.kind = .listItem(ordered: ordered, task: task)
      return b

    case "fenced_code_block":
      var b = Block(kind: .code(language: nil), range: rel)
      var language: String?
      var delimiters: [NSRange] = []
      for c in kids() {
        switch c.nodeType {
        case "fenced_code_block_delimiter": delimiters.append(relr(c))
        case "info_string":
          c.enumerateChildren { l in
            if l.nodeType == "language" { language = text.substring(with: l.range) }
          }
        case "code_fence_content": b.content = relr(c)
        default: break
        }
      }
      // Hide each fence line whole (delimiter + info string), not its newline.
      for d in delimiters {
        b.markers.append(lineContaining(d, base: base, text: text))
      }
      if let lang = language?.lowercased(), let kind = DiagramKind(rawValue: lang),
        preferences.diagrams
      {
        b.kind = .diagram(kind)
      } else {
        b.kind = .code(language: language)
      }
      b.info = language
      return b

    case "indented_code_block":
      var b = Block(kind: .code(language: nil), range: rel)
      b.content = rel
      return b

    case "pipe_table":
      var b = Block(kind: .table, range: rel)
      b.content = rel
      return b

    case "thematic_break":
      var b = Block(kind: .thematicBreak, range: rel)
      b.markers = [trimNewline(rel, base: base, text: text)]
      return b

    case "html_block":
      let s = text.substring(with: r)
      var b = Block(kind: .html, range: rel)
      b.info = s
      let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.hasPrefix("<!--") {
        b.kind = .comment
      } else if trimmed.range(
        of: #"^<div\s+style\s*=\s*["']\s*page-break-after\s*:\s*always;?\s*["']\s*>\s*</div>$"#,
        options: [.regularExpression, .caseInsensitive]) != nil
      {
        b.kind = .pageBreak
      }
      b.markers = [trimNewline(rel, base: base, text: text)]
      return b

    case "link_reference_definition":
      var label = ""
      var dest = ""
      for c in kids() {
        if c.nodeType == "link_label" { label = text.substring(with: c.range) }
        if c.nodeType == "link_destination" { dest = text.substring(with: c.range) }
      }
      if label.hasPrefix("[^") {
        var b = Block(kind: .paragraph, range: rel)
        classifyParagraph(&b, base: base, text: text)
        return b
      }
      var b = Block(kind: .linkReferenceDefinition, range: rel)
      b.info = label.dropFirst().dropLast().lowercased() + "\u{0}" + dest
      b.markers = [trimNewline(rel, base: base, text: text)]
      return b

    case "minus_metadata", "plus_metadata":
      var b = Block(kind: .frontMatter, range: rel)
      b.info = text.substring(with: r)
      return b

    case "block_continuation", "block_quote_marker":
      return nil

    default:
      return Block(kind: .paragraph, range: rel)
    }
  }

  private func classifyParagraph(_ b: inout Block, base: Int, text: NSString) {
    let abs = b.range.shifted(by: base)
    let s = text.substring(with: abs)
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = trimmed.first, "[$#*_".contains(first) else { return }
    // The grammar misses `***` / `___` on the last line without a newline.
    if first == "*" || first == "_", trimmed.allSatisfy({ $0 == first || $0 == " " }),
      trimmed.filter({ $0 == first }).count >= 3
    {
      b.kind = .thematicBreak
      b.inlines = []
      b.markers = [trimNewline(b.range, base: base, text: text)]
      return
    }
    if trimmed.caseInsensitiveCompare("[toc]") == .orderedSame {
      b.kind = .toc
      b.inlines = []
      b.markers = [trimNewline(b.range, base: base, text: text)]
      return
    }
    // A paragraph that is exactly `$$ … $$` is a math block.
    if trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"), trimmed.count >= 4 {
      let ns = s as NSString
      let open = ns.range(of: "$$")
      let close = ns.range(of: "$$", options: .backwards)
      if open.location != close.location {
        b.kind = .math
        b.inlines = []
        let inner = NSRange(location: open.end, length: close.location - open.end)
        b.content = inner.shifted(by: b.range.location)
        b.markers = [trimNewline(b.range, base: base, text: text)]
        return
      }
    }
    // Footnote definition: `[^id]: text`.
    if let m = s.firstMatch(of: #/^\[\^([^\]\s]+)\]:[ \t]?/#) {
      b.kind = .footnoteDefinition(String(m.1))
      let markerLen = m.0.utf16.count
      b.markers = [NSRange(location: b.range.location, length: markerLen)]
      let rest = NSRange(location: abs.location + markerLen, length: abs.length - markerLen)
      b.inlines = parseInlineText(range: rest, masks: [], base: base, text: text)
      return
    }
    // Non-strict mode: `###Heading` without a space.
    if !preferences.strictMode, !s.dropLast(s.hasSuffix("\n") ? 1 : 0).contains("\n"),
      let m = s.firstMatch(of: #/^(#{1,6})(?=[^#\s])/#)
    {
      let n = m.1.count
      b.kind = .heading(n)
      b.markers = [NSRange(location: b.range.location, length: n)]
      b.inlines = parseInlineText(
        range: NSRange(
          location: abs.location + n,
          length: trimNewline(b.range, base: base, text: text).length - n),
        masks: [], base: base, text: text)
    }
  }

  private func collectQuoteMarkers(
    _ node: Node, base: Int, text: NSString, into markers: inout [NSRange]
  ) {
    node.enumerateChildren { c in
      switch c.nodeType {
      case "block_quote_marker":
        markers.append(NSRange(location: c.range.location - base, length: c.range.length))
      case "block_continuation":
        // Hide up to and including the last `>` and one following space; leave list indentation.
        let s = text.substring(with: c.range) as NSString
        let gt = s.range(of: ">", options: .backwards)
        if gt.location != NSNotFound {
          var len = gt.end
          if len < s.length, s.character(at: len) == 0x20 { len += 1 }
          markers.append(NSRange(location: c.range.location - base, length: len))
        }
      case "block_quote": break  // nested quote collects its own
      default:
        self.collectQuoteMarkers(c, base: base, text: text, into: &markers)
      }
    }
  }

  private func trimNewline(_ rel: NSRange, base: Int, text: NSString) -> NSRange {
    var len = rel.length
    while len > 0 {
      let ch = text.character(at: base + rel.location + len - 1)
      if ch == 0x0A || ch == 0x0D { len -= 1 } else { break }
    }
    return NSRange(location: rel.location, length: len)
  }

  private func lineContaining(_ rel: NSRange, base: Int, text: NSString) -> NSRange {
    var line = text.lineRange(for: NSRange(location: base + rel.location, length: 0)).shifted(
      by: -base)
    // Never reach before the block: cached blocks must not depend on text outside them.
    if line.location < 0 { line = NSRange(location: 0, length: line.end) }
    return trimNewline(line, base: base, text: text)
  }

  private func lineIncludingPrecedingNewline(_ rel: NSRange, base: Int, text: NSString) -> NSRange {
    let line = lineContaining(rel, base: base, text: text)
    if line.location > 0 { return NSRange(location: line.location - 1, length: line.length + 1) }
    return line
  }

  // MARK: Inlines

  private func inlines(of node: Node, base: Int, text: NSString) -> [Inline] {
    var masks: [NSRange] = []
    func findMasks(_ n: Node) {
      n.enumerateChildren { c in
        if c.nodeType == "block_continuation" { masks.append(c.range) } else { findMasks(c) }
      }
    }
    findMasks(node)
    return parseInlineText(range: node.range, masks: masks, base: base, text: text)
  }

  /// Parse `range` (absolute) as inline markdown; `masks` (absolute) become spaces so
  /// offsets stay aligned. Returned ranges are relative to `base`.
  func parseInlineText(range: NSRange, masks: [NSRange], base: Int, text: NSString) -> [Inline] {
    guard range.length > 0 else { return [] }
    let sub = NSMutableString(string: text.substring(with: range))
    for m in masks {
      let local = NSRange(location: m.location - range.location, length: m.length)
      guard local.location >= 0, local.end <= sub.length else { continue }
      sub.replaceCharacters(in: local, with: String(repeating: " ", count: local.length))
    }
    let s = sub as String
    guard let root = inlineParser.parse(s)?.rootNode else { return [] }
    let off = range.location - base
    var result = walk(root, off: off, s: sub)
    result.append(contentsOf: pairHTML(&result))
    result.append(contentsOf: scanExtensions(s: sub, off: off, existing: result))
    result.sort { $0.range.location < $1.range.location }
    return result
  }

  private func walk(_ node: Node, off: Int, s: NSString) -> [Inline] {
    var out: [Inline] = []
    node.enumerateChildren { c in
      if let i = self.inline(from: c, off: off, s: s) {
        out.append(i)
      } else {
        out.append(contentsOf: self.walk(c, off: off, s: s))
      }
    }
    return out
  }

  private func inline(from n: Node, off: Int, s: NSString) -> Inline? {
    let r = n.range.shifted(by: off)
    func childNodes() -> [Node] {
      var a: [Node] = []
      n.enumerateChildren { a.append($0) }
      return a
    }
    func text(_ node: Node) -> String { s.substring(with: node.range) }
    switch n.nodeType {
    case "emphasis", "strong_emphasis", "strikethrough":
      var i = Inline(kind: .emphasis, range: r)
      let cs = childNodes()
      i.markers = cs.filter { $0.nodeType == "emphasis_delimiter" }.map {
        $0.range.shifted(by: off)
      }
      i.children = walk(n, off: off, s: s)
      switch n.nodeType {
      case "strong_emphasis": i.kind = .strong
      case "strikethrough":
        // `~~x~~` parses as strike(~ strike(~x~) ~): merge into one.
        if i.children.count == 1, [.strikethrough, .subscript].contains(i.children[0].kind),
          i.children[0].range.location == r.location + 1, i.children[0].range.end == r.end - 1
        {
          i.markers += i.children[0].markers
          i.children = i.children[0].children
          i.kind = .strikethrough
        } else if i.markers.count == 2, preferences.subscript {
          i.kind = .subscript
        } else {
          i.kind = .strikethrough
        }
      default: break
      }
      return i

    case "code_span":
      var i = Inline(kind: .code, range: r)
      i.markers = childNodes().filter { $0.nodeType == "code_span_delimiter" }.map {
        $0.range.shifted(by: off)
      }
      return i

    case "inline_link", "full_reference_link", "collapsed_reference_link":
      let cs = childNodes()
      guard let textNode = cs.first(where: { $0.nodeType == "link_text" }) else { return nil }
      let t = textNode.range.shifted(by: off)
      var dest = cs.first(where: { $0.nodeType == "link_destination" }).map(text) ?? ""
      if n.nodeType == "full_reference_link",
        let label = cs.first(where: { $0.nodeType == "link_label" })
      {
        dest = "ref:" + text(label).dropFirst().dropLast().lowercased()
      } else if n.nodeType == "collapsed_reference_link" {
        dest = "ref:" + text(textNode).lowercased()
      }
      if dest.hasPrefix("<"), dest.hasSuffix(">") { dest = String(dest.dropFirst().dropLast()) }
      var i = Inline(kind: .link(dest), range: r)
      i.markers = [
        NSRange(location: r.location, length: t.location - r.location),
        NSRange(location: t.end, length: r.end - t.end),
      ].filter { $0.length > 0 }
      i.children = walk(textNode, off: off, s: s)
      return i

    case "shortcut_link":
      let cs = childNodes()
      guard let textNode = cs.first(where: { $0.nodeType == "link_text" }) else { return nil }
      let label = text(textNode)
      if label.hasPrefix("^") {
        var i = Inline(kind: .footnoteRef(String(label.dropFirst())), range: r)
        i.markers = [r]
        return i
      }
      let t = textNode.range.shifted(by: off)
      var i = Inline(kind: .link("ref:" + label.lowercased()), range: r)
      i.markers = [
        NSRange(location: r.location, length: 1), NSRange(location: t.end, length: r.end - t.end),
      ]
      i.children = walk(textNode, off: off, s: s)
      return i

    case "image":
      let cs = childNodes()
      let alt = cs.first(where: { $0.nodeType == "image_description" }).map(text) ?? ""
      var src = cs.first(where: { $0.nodeType == "link_destination" }).map(text) ?? ""
      if src.hasPrefix("<"), src.hasSuffix(">") { src = String(src.dropFirst().dropLast()) }
      var i = Inline(kind: .image(source: src, alt: alt), range: r)
      i.markers = [r]
      return i

    case "uri_autolink", "email_autolink":
      let url = String(text(n).dropFirst().dropLast())
      var i = Inline(
        kind: .autolink(n.nodeType == "email_autolink" ? "mailto:" + url : url), range: r)
      i.markers = [
        NSRange(location: r.location, length: 1), NSRange(location: r.end - 1, length: 1),
      ]
      return i

    case "html_tag":
      let t = text(n)
      if t.hasPrefix("<!--") {
        var i = Inline(kind: .comment, range: r)
        i.markers = [r]
        return i
      }
      // Paired later by `pairHTML`, which reads the tag text from here.
      tagTexts[r.location] = t
      return Inline(kind: .html(HTMLStyle(hidden: true)), range: r, markers: [r])

    case "latex_block":
      let delims = childNodes().filter { $0.nodeType == "latex_span_delimiter" }
      guard delims.count >= 2 else { return nil }
      let d = delims[0].range.length
      let inner = NSRange(
        location: delims[0].range.end,
        length: delims[delims.count - 1].range.location - delims[0].range.end)
      guard inner.length > 0 else { return nil }
      let latex = s.substring(with: inner)
      if d == 1 {
        guard preferences.inlineMath else { return nil }
        // Pandoc rules: no space inside the delimiters, no digit right after the closing `$`.
        guard let first = latex.first, let last = latex.last, !first.isWhitespace,
          !last.isWhitespace
        else { return nil }
        let after = n.range.end
        if after < s.length, let u = UnicodeScalar(s.character(at: after)),
          CharacterSet.decimalDigits.contains(u)
        {
          return nil
        }
      }
      var i = Inline(kind: .math(latex), range: r)
      i.markers = [r]
      return i

    case "backslash_escape":
      return Inline(kind: .escape, range: r, markers: [NSRange(location: r.location, length: 1)])

    case "entity_reference", "numeric_character_reference":
      guard let ch = HTMLEntities.decode(text(n)) else { return nil }
      return Inline(kind: .entity(ch), range: r, markers: [r])

    default:
      return nil
    }
  }

  /// Pair `<u>…</u>`-style tags (already collected as hidden html inlines) into styled spans.
  private func pairHTML(_ list: inout [Inline]) -> [Inline] {
    var stack: [(name: String, inline: Inline, attrs: String)] = []
    var paired: [Inline] = []
    for (idx, item) in list.enumerated() {
      guard case .html = item.kind, let t = tagTexts[item.range.location] else { continue }
      guard let m = t.firstMatch(of: #/^<(/?)([A-Za-z][A-Za-z0-9]*)([^>]*?)(/?)>$/#) else {
        continue
      }
      let closing = !m.1.isEmpty
      let name = m.2.lowercased()
      let attrs = String(m.3)
      // `<img>` behaves like `![]()`, with its width/zoom kept for sizing.
      if name == "img", let img = ImageTag.parse(t) {
        list[idx] = Inline(
          kind: .image(source: img.src, alt: img.alt), range: item.range, markers: [item.range],
          size: img.size)
        continue
      }
      if ["br", "hr", "input", "source", "wbr"].contains(name) || !m.4.isEmpty { continue }
      if !closing {
        stack.append((name, item, attrs))
      } else if let open = stack.lastIndex(where: { $0.name == name }) {
        let o = stack[open]
        stack.removeSubrange(open...)
        var style = HTMLStyle()
        switch name {
        case "u", "ins": style.underline = true
        case "b", "strong": style.bold = true
        case "i", "em": style.italic = true
        case "kbd": style.kbd = true
        case "sup": style.superscript = true
        case "sub": style.subscript = true
        case "mark": style.mark = true
        case "span", "font": HTMLStyle.parseCSS(o.attrs, into: &style)
        default: break
        }
        paired.append(
          Inline(
            kind: .html(style),
            range: NSRange(
              location: o.inline.range.location, length: item.range.end - o.inline.range.location),
            markers: [o.inline.range, item.range]))
      }
    }
    tagTexts.removeAll()
    return paired
  }

  private var tagTexts: [Int: String] = [:]

  /// Highlight, superscript, emoji and bare URLs: things the grammar doesn't know.
  private func scanExtensions(s: NSString, off: Int, existing: [Inline]) -> [Inline] {
    var covered: [NSRange] = []
    func cover(_ list: [Inline]) {
      for i in list {
        switch i.kind {
        case .code, .math, .image, .autolink, .comment, .html, .entity, .footnoteRef:
          covered.append(i.range.shifted(by: -off))
        case .link: covered.append(contentsOf: i.markers.map { $0.shifted(by: -off) })
        default: break
        }
        cover(i.children)
      }
    }
    cover(existing)
    func free(_ r: NSRange) -> Bool { !covered.contains { NSIntersectionRange($0, r).length > 0 } }
    var out: [Inline] = []
    // Cheap prechecks first: regexes and the link detector are the slow part of a full parse.
    let plain = NSMutableString(string: s)
    for c in covered where c.end <= plain.length {
      plain.replaceCharacters(in: c, with: String(repeating: " ", count: c.length))
    }
    let str = s as String
    let visible = plain as String
    if preferences.highlight, visible.contains("==") {
      for m in str.matches(of: #/==(?=\S)([^=\n]*?\S)==/#) {
        let r = NSRange(m.range, in: str)
        guard free(r) else { continue }
        out.append(
          Inline(
            kind: .highlight, range: r.shifted(by: off),
            markers: [
              NSRange(location: r.location + off, length: 2),
              NSRange(location: r.end + off - 2, length: 2),
            ]))
      }
    }
    if preferences.superscript, visible.contains("^") {
      for m in str.matches(of: #/\^([^\s^]+)\^/#) {
        let r = NSRange(m.range, in: str)
        guard free(r) else { continue }
        out.append(
          Inline(
            kind: .superscript, range: r.shifted(by: off),
            markers: [
              NSRange(location: r.location + off, length: 1),
              NSRange(location: r.end + off - 1, length: 1),
            ]))
      }
    }
    if visible.filter({ $0 == ":" }).count >= 2 {
      for m in str.matches(of: #/:([a-z0-9_+\-]+):/#) {
        let r = NSRange(m.range, in: str)
        guard free(r), let emoji = EmojiTable.shared.emoji(for: String(m.1)) else { continue }
        out.append(
          Inline(kind: .emoji(emoji), range: r.shifted(by: off), markers: [r.shifted(by: off)]))
      }
    }
    if visible.contains("www.") || visible.contains("://") {
      for m in Self.linkDetector.matches(in: str, range: NSRange(location: 0, length: s.length)) {
        guard let url = m.url, free(m.range) else { continue }
        // Skip text that's already inside a link.
        if existing.contains(where: {
          if case .link = $0.kind {
            return $0.range.shifted(by: -off).contains(m.range.location)
          } else {
            return false
          }
        }) {
          continue
        }
        out.append(Inline(kind: .autolink(url.absoluteString), range: m.range.shifted(by: off)))
      }
    }
    return out
  }

  private static let linkDetector = try! NSDataDetector(
    types: NSTextCheckingResult.CheckingType.link.rawValue)

}

func forEachInline(_ b: Block, _ f: (Inline) -> Void) {
  func go(_ list: [Inline]) {
    for i in list {
      f(i)
      go(i.children)
    }
  }
  go(b.inlines)
  for c in b.children { forEachInline(c, f) }
}

extension HeadingInfo {
  /// GitHub/Typora-style anchor: lowercase, punctuation dropped, spaces → `-`.
  static func slug(_ title: String) -> String {
    var out = ""
    for ch in title.lowercased() {
      if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" {
        out.append(ch)
      } else if ch == " " {
        out.append("-")
      }
    }
    return out
  }
}

extension HTMLStyle {
  static func parseCSS(_ attrs: String, into style: inout HTMLStyle) {
    guard let m = attrs.firstMatch(of: #/style\s*=\s*["']([^"']*)["']/#.ignoresCase()) else {
      if let c = attrs.firstMatch(of: #/color\s*=\s*["']?([#\w]+)/#.ignoresCase()) {
        style.color = String(c.1)
      }
      return
    }
    for decl in m.1.split(separator: ";") {
      let kv = decl.split(separator: ":", maxSplits: 1).map {
        $0.trimmingCharacters(in: .whitespaces).lowercased()
      }
      guard kv.count == 2 else { continue }
      switch kv[0] {
      case "color": style.color = kv[1]
      case "background", "background-color": style.background = kv[1]
      case "font-weight": style.bold = kv[1] == "bold" || (Int(kv[1]) ?? 400) >= 600
      case "font-style": style.italic = kv[1] == "italic"
      case "text-decoration": style.underline = kv[1].contains("underline")
      case "font-size":
        if kv[1].hasSuffix("em"), let v = Double(kv[1].dropLast(2)) { style.fontScale = v }
        if kv[1].hasSuffix("%"), let v = Double(kv[1].dropLast()) { style.fontScale = v / 100 }
        if kv[1].hasSuffix("px"), let v = Double(kv[1].dropLast(2)) { style.fontScale = v / 16 }
      default: break
      }
    }
  }
}

/// For handing non-Sendable values to `concurrentPerform` workers that only read them.
struct UncheckedBox<T>: @unchecked Sendable {
  var value: T
  init(_ value: T) { self.value = value }
}
