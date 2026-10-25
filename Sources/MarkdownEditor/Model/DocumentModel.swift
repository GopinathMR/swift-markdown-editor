import Foundation

/// What a block is. Ranges inside a `Block` are relative to its top-level entry's start,
/// so an unchanged block can be reused from the parse cache wherever it moves.
enum BlockKind: Equatable, Sendable {
  case paragraph
  case heading(Int)
  case setextHeading(Int)
  case blockquote
  case callout(CalloutType)
  case list
  case listItem(ordered: Bool, task: Bool?)  // task: nil = not a task, else checked
  case code(language: String?)
  case diagram(DiagramKind)
  case math
  case table
  case thematicBreak
  case frontMatter
  case toc
  case html
  case comment
  case pageBreak
  case footnoteDefinition(String)
  case linkReferenceDefinition
}

enum CalloutType: String, CaseIterable, Sendable {
  case note = "NOTE"
  case tip = "TIP"
  case important = "IMPORTANT"
  case warning = "WARNING"
  case caution = "CAUTION"
  var title: String { rawValue.prefix(1) + rawValue.dropFirst().lowercased() }
}

enum DiagramKind: String, Sendable {
  case mermaid, flow, sequence
}

struct Block: Equatable, Sendable {
  var kind: BlockKind
  var range: NSRange
  /// Block syntax hidden in rendered mode: `#`, fences, `>` prefixes, setext underlines.
  var markers: [NSRange] = []
  /// List bullet / number (drawn over), task box.
  var listMarker: NSRange?
  var taskMarker: NSRange?
  /// Code content, math source, table body, etc.
  var content: NSRange?
  var inlines: [Inline] = []
  var children: [Block] = []
  /// Block-specific payload: link-ref label → destination, html source, list start, etc.
  var info: String?
}

enum InlineKind: Equatable, Sendable {
  case emphasis, strong, strikethrough, code, highlight, superscript, `subscript`
  case link(String)
  case autolink(String)
  case image(source: String, alt: String)
  case math(String)
  case emoji(String)
  case footnoteRef(String)
  case entity(String)
  case escape
  case html(HTMLStyle)
  case comment
}

/// The subset of inline HTML Typora styles in the editor.
struct HTMLStyle: Equatable, Sendable {
  var underline = false
  var bold = false
  var italic = false
  var kbd = false
  var superscript = false
  var `subscript` = false
  var mark = false
  var color: String?
  var background: String?
  var fontScale: Double?
  var hidden = false  // <br>, unknown tags: hide the tag, keep content
}

struct Inline: Equatable, Sendable {
  var kind: InlineKind
  var range: NSRange
  /// Delimiters hidden unless the caret is inside `range`.
  var markers: [NSRange] = []
  var children: [Inline] = []
  /// Image size from `<img width>` / `style="zoom:…"`: "50%", "300", "zoom:50%".
  var size: String? = nil
}

struct BlockEntry: Sendable {
  var start: Int
  var block: Block
  var length: Int { block.range.length }
  var range: NSRange { NSRange(location: start, length: block.range.length) }
}

struct HeadingInfo: Equatable, Sendable {
  var level: Int
  var title: String
  var slug: String
  var range: NSRange
  var number: String?
}

struct DocumentModel: Sendable {
  var entries: [BlockEntry] = []
  var headings: [HeadingInfo] = []
  var linkRefs: [String: String] = [:]
  /// Footnote id → display number, in reference order.
  var footnoteNumbers: [String: Int] = [:]
  var footnoteDefinitions: [String: NSRange] = [:]
  var frontMatter: String?

  /// Index of the top-level entry containing `location` (or the last one starting before it).
  func entryIndex(at location: Int) -> Int? {
    guard !entries.isEmpty else { return nil }
    var lo = 0
    var hi = entries.count - 1
    while lo < hi {
      let mid = (lo + hi + 1) / 2
      if entries[mid].start <= location { lo = mid } else { hi = mid - 1 }
    }
    return entries[lo].start <= location ? lo : nil
  }

  func entry(at location: Int) -> BlockEntry? {
    entryIndex(at: location).map { entries[$0] }
  }

  /// The innermost block containing `location`, with its absolute offset.
  func innermostBlock(at location: Int) -> (block: Block, offset: Int)? {
    guard let e = entry(at: location) else { return nil }
    var block = e.block
    let rel = location - e.start
    while let child = block.children.first(where: {
      $0.range.contains(rel) || NSMaxRange($0.range) == rel
    }) {
      block = child
    }
    return (block, e.start)
  }

  func inline(at location: Int) -> (inline: Inline, offset: Int)? {
    guard let (block, offset) = innermostBlock(at: location) else { return nil }
    let rel = location - offset
    func find(_ list: [Inline]) -> Inline? {
      for i in list where i.range.contains(rel) {
        return find(i.children) ?? i
      }
      return nil
    }
    return find(block.inlines).map { ($0, offset) }
  }
}

extension NSRange {
  func shifted(by d: Int) -> NSRange { NSRange(location: location + d, length: length) }
  var end: Int { location + length }
  /// Caret-touching: the caret at either edge counts as inside, as in Typora.
  func touches(_ caret: NSRange) -> Bool {
    caret.location <= end && caret.end >= location
  }
}

extension DocumentModel {
  /// Every block (any depth) matching `predicate`, with its absolute offset.
  func blocks(where predicate: (BlockKind) -> Bool) -> [(block: Block, offset: Int)] {
    var out: [(Block, Int)] = []
    func walk(_ b: Block, _ off: Int) {
      if predicate(b.kind) { out.append((b, off)) }
      for c in b.children { walk(c, off) }
    }
    for e in entries { walk(e.block, e.start) }
    return out
  }
}
