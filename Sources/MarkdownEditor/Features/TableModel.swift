import AppKit

enum ColumnAlignment: Equatable, Sendable { case none, left, center, right }

/// One GFM pipe table. Parsing and serialising touch only that table's lines.
struct TableModel: Equatable, Sendable {
  var header: [String]
  var rows: [[String]]
  var alignments: [ColumnAlignment]

  var columnCount: Int { header.count }

  init(header: [String], rows: [[String]], alignments: [ColumnAlignment]) {
    self.header = header
    self.rows = rows
    self.alignments = alignments
    normalize()
  }

  init?(source: String) {
    let lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
      .map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    guard lines.count >= 2 else { return nil }
    let delim = Self.cells(lines[1])
    guard !delim.isEmpty,
      delim.allSatisfy({ $0.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil })
    else { return nil }
    header = Self.cells(lines[0])
    alignments = delim.map { d in
      switch (d.hasPrefix(":"), d.hasSuffix(":")) {
      case (true, true): return .center
      case (true, false): return .left
      case (false, true): return .right
      default: return .none
      }
    }
    rows = lines.dropFirst(2).map(Self.cells)
    normalize()
  }

  private mutating func normalize() {
    let n = max(header.count, alignments.count, rows.map(\.count).max() ?? 0, 1)
    header += Array(repeating: "", count: n - header.count)
    alignments += Array(repeating: .none, count: n - alignments.count)
    rows = rows.map {
      $0.count < n ? $0 + Array(repeating: "", count: n - $0.count) : Array($0.prefix(n))
    }
  }

  /// Split a row on unescaped `|`, trimming the outer pipes and cell whitespace.
  static func cells(_ line: String) -> [String] {
    var s = line.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("|") { s.removeFirst() }
    if s.hasSuffix("|"), !s.hasSuffix("\\|") { s.removeLast() }
    var out: [String] = []
    var cur = ""
    var escaped = false
    var inCode = false
    for ch in s {
      if escaped {
        cur.append(ch == "|" ? "|" : "\\\(ch)")
        escaped = false
      } else if ch == "\\" {
        escaped = true
      } else if ch == "`" {
        inCode.toggle()
        cur.append(ch)
      } else if ch == "|", !inCode {
        out.append(cur.trimmingCharacters(in: .whitespaces))
        cur = ""
      } else {
        cur.append(ch)
      }
    }
    if escaped { cur.append("\\") }
    out.append(cur.trimmingCharacters(in: .whitespaces))
    return out
  }

  private static func escape(_ cell: String) -> String {
    cell.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "\\|")
  }

  /// Padded GFM, column widths regenerated.
  func serialized(eol: String = "\n") -> String {
    let all = [header] + rows
    var widths = (0..<columnCount).map { c in
      max(3, all.map { Self.escape($0[c]).count }.max() ?? 3)
    }
    for c in 0..<columnCount where alignments[c] == .center { widths[c] = max(widths[c], 5) }
    func line(_ cells: [String]) -> String {
      "| "
        + cells.enumerated().map { c, v in
          let e = Self.escape(v)
          let pad = widths[c] - e.count
          switch alignments[c] {
          case .right: return String(repeating: " ", count: pad) + e
          case .center:
            return String(repeating: " ", count: pad / 2) + e
              + String(repeating: " ", count: pad - pad / 2)
          default: return e + String(repeating: " ", count: pad)
          }
        }.joined(separator: " | ") + " |"
    }
    let delim =
      "| "
      + (0..<columnCount).map { c in
        let w = widths[c]
        switch alignments[c] {
        case .left: return ":" + String(repeating: "-", count: w - 1)
        case .right: return String(repeating: "-", count: w - 1) + ":"
        case .center: return ":" + String(repeating: "-", count: w - 2) + ":"
        case .none: return String(repeating: "-", count: w)
        }
      }.joined(separator: " | ") + " |"
    return ([line(header), delim] + rows.map(line)).joined(separator: eol)
  }

  // MARK: Mutations. Row index -1 = header.

  subscript(row: Int, col: Int) -> String {
    get { row < 0 ? header[col] : rows[row][col] }
    set { if row < 0 { header[col] = newValue } else { rows[row][col] = newValue } }
  }

  mutating func insertRow(at i: Int) {
    rows.insert(Array(repeating: "", count: columnCount), at: max(0, min(i, rows.count)))
  }

  mutating func deleteRow(at i: Int) {
    guard rows.indices.contains(i) else { return }
    rows.remove(at: i)
  }

  mutating func insertColumn(at i: Int) {
    let c = max(0, min(i, columnCount))
    header.insert("", at: c)
    alignments.insert(.none, at: c)
    for r in rows.indices { rows[r].insert("", at: c) }
  }

  mutating func deleteColumn(at i: Int) {
    guard columnCount > 1, header.indices.contains(i) else { return }
    header.remove(at: i)
    alignments.remove(at: i)
    for r in rows.indices { rows[r].remove(at: i) }
  }

  mutating func moveRow(from: Int, to: Int) {
    guard rows.indices.contains(from), rows.indices.contains(to) else { return }
    rows.insert(rows.remove(at: from), at: to)
  }

  mutating func moveColumn(from: Int, to: Int) {
    guard header.indices.contains(from), header.indices.contains(to) else { return }
    header.insert(header.remove(at: from), at: to)
    alignments.insert(alignments.remove(at: from), at: to)
    for r in rows.indices { rows[r].insert(rows[r].remove(at: from), at: to) }
  }

  /// Grow or shrink to `rows` body rows × `columns` columns, keeping content.
  mutating func resize(rows r: Int, columns c: Int) {
    while columnCount < c { insertColumn(at: columnCount) }
    while columnCount > max(1, c) { deleteColumn(at: columnCount - 1) }
    while rows.count < r { insertRow(at: rows.count) }
    while rows.count > max(0, r) { rows.removeLast() }
  }
}

/// Column widths and row heights shared by the styler (space to reserve) and the grid.
enum TableLayout {
  struct Metrics {
    var columnWidths: [CGFloat]
    var rowHeights: [CGFloat]  // header first
    var size: CGSize {
      CGSize(width: columnWidths.reduce(0, +) + 1, height: rowHeights.reduce(0, +) + 1)
    }
  }

  static let padX: CGFloat = 10
  static let padY: CGFloat = 6

  @MainActor static func metrics(_ t: TableModel, theme: ResolvedTheme, width: CGFloat) -> Metrics {
    let font = theme.body
    let bold = theme.font(bold: true, italic: false)
    func w(_ s: String, _ f: NSFont) -> CGFloat {
      ceil((s as NSString).size(withAttributes: [.font: f]).width)
    }
    var widths = (0..<t.columnCount).map { c in
      max(48, max(w(t.header[c], bold), t.rows.map { w($0[c], font) }.max() ?? 0) + 2 * padX + 8)  // + NSTextField cell inset
    }
    let total = widths.reduce(0, +)
    if total > width {
      // Shrink proportionally; text wraps inside narrower cells.
      widths = widths.map { max(48, $0 * width / total) }
    }
    func h(_ s: String, _ f: NSFont, _ cw: CGFloat) -> CGFloat {
      let r = (s.isEmpty ? " " : s as NSString).boundingRect(
        with: CGSize(width: cw - 2 * padX, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin],
        attributes: [.font: f])
      return ceil(r.height) + 2 * padY
    }
    var heights = [(0..<t.columnCount).map { h(t.header[$0], bold, widths[$0]) }.max() ?? 24]
    for row in t.rows {
      heights.append((0..<t.columnCount).map { h(row[$0], font, widths[$0]) }.max() ?? 24)
    }
    return Metrics(columnWidths: widths, rowHeights: heights)
  }

  @MainActor static func size(_ t: TableModel, theme: ResolvedTheme, width: CGFloat) -> CGSize {
    metrics(t, theme: theme, width: width).size
  }
}
