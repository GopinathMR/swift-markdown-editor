import AppKit
import SwiftUI

/// Live views pinned over reserved block space: table grids (and media, added by that layer).
/// They are subviews of the text view, so they scroll with it; we only re-place them when
/// layout changes.
@MainActor
final class OverlayState {
  final class Table {
    let grid: TableGridView
    var range: NSRange
    init(grid: TableGridView, range: NSRange) {
      self.grid = grid
      self.range = range
    }
  }
  var tables: [Table] = []
  let toolbar = TableToolbar()
  var scheduled = false
  var media: [MediaOverlay] = []
}

extension EditorCoordinator {
  func overlaysNeedUpdate() {
    guard !overlays.scheduled else { return }
    overlays.scheduled = true
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        self?.overlays.scheduled = false
        self?.layoutOverlays()
      }
    }
  }

  func viewportDidScroll() { overlaysNeedUpdate() }

  /// Character range on screen, padded by a screenful each way.
  func nearViewport() -> NSRange {
    guard let lm = textView.textLayoutManager, let cs = lm.textContentManager,
      let v = lm.textViewportLayoutController.viewportRange
    else { return NSRange(location: 0, length: text.length) }
    let a = cs.offset(from: cs.documentRange.location, to: v.location)
    let b = cs.offset(from: cs.documentRange.location, to: v.endLocation)
    let pad = max(4000, b - a)
    let lo = max(0, a - pad)
    return NSRange(location: lo, length: min(text.length, b + pad) - lo)
  }

  private var padding: CGFloat { textView.textContainer?.lineFragmentPadding ?? 5 }

  /// Top-left (in text view coordinates) of the reserved space before `location`'s line.
  func reservedOrigin(at location: Int) -> CGPoint? {
    guard let lm = textView.textLayoutManager, let cs = lm.textContentManager,
      let loc = cs.location(cs.documentRange.location, offsetBy: location)
    else { return nil }
    // Exact positions need everything above laid out, not estimated.
    lm.ensureLayout(
      for: NSTextRange(location: cs.documentRange.location, end: loc) ?? cs.documentRange)
    guard let f = lm.textLayoutFragment(for: loc) else { return nil }
    let origin = textView.textContainerOrigin
    return CGPoint(
      x: origin.x + f.layoutFragmentFrame.minX, y: origin.y + f.layoutFragmentFrame.minY)
  }

  func layoutOverlays() {
    let near = nearViewport()
    let tables =
      mode == .rendered
      ? model.blocks(where: { $0 == .table }).filter {
        NSIntersectionRange($0.block.range.shifted(by: $0.offset), near).length > 0
      } : []
    while overlays.tables.count > tables.count {
      overlays.tables.removeLast().grid.removeFromSuperview()
    }
    for (i, (b, off)) in tables.enumerated() {
      var range = b.range.shifted(by: off)
      while range.length > 0, [0x0A, 0x0D].contains(text.character(at: range.end - 1)) {
        range.length -= 1
      }
      guard let tm = TableModel(source: text.substring(with: range)) else { continue }
      let style =
        storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
        as? NSParagraphStyle
      let indent = style?.firstLineHeadIndent ?? 0
      let width = max(100, (textView.textContainer?.size.width ?? 600) - 2 * padding - indent - 10)
      let entry: OverlayState.Table
      if i < overlays.tables.count {
        entry = overlays.tables[i]
        entry.range = range
        entry.grid.update(model: tm, theme: styler.theme, width: width)
      } else {
        let grid = TableGridView(model: tm, theme: styler.theme, width: width)
        entry = OverlayState.Table(grid: grid, range: range)
        wire(entry)
        overlays.tables.append(entry)
        textView.addSubview(grid)
      }
      if let o = reservedOrigin(at: range.location) {
        entry.grid.setFrameOrigin(CGPoint(x: o.x + indent, y: o.y + Styler.tableGap))
      }
    }
    layoutMediaOverlays()
    placeToolbar()
    // Our ensureLayout calls can leave the viewport stale; redraw what is on screen.
    textView.textLayoutManager?.textViewportLayoutController.layoutViewport()
  }

  private func wire(_ entry: OverlayState.Table) {
    entry.grid.onChange = { [weak self, weak entry] m in
      guard let self, let entry else { return }
      self.replace(entry.range, with: m.serialized(eol: self.eol))
    }
    entry.grid.onExit = { [weak self, weak entry] dir in
      guard let self, let entry else { return }
      self.textView.window?.makeFirstResponder(self.textView)
      let loc =
        dir == .above
        ? max(0, entry.range.location - 1) : min(self.text.length, entry.range.end + 1)
      self.textView.setSelectedRange(NSRange(location: loc, length: 0))
    }
    entry.grid.onFocusChange = { [weak self] _ in self?.placeToolbar() }
  }

  private func placeToolbar() {
    let bar = overlays.toolbar
    guard let entry = overlays.tables.first(where: { $0.grid.focused != nil }) else {
      bar.removeFromSuperview()
      return
    }
    bar.grid = entry.grid
    bar.onResize = { [weak self, weak entry] in
      guard let self, let entry else { return }
      self.showTableSizePicker(
        rows: entry.grid.model.rows.count, cols: entry.grid.model.columnCount,
        near: entry.grid.frame
      ) { r, c in
        entry.grid.apply { $0.resize(rows: r, columns: c) }
      }
    }
    bar.onDelete = { [weak self, weak entry] in
      guard let self, let entry else { return }
      self.textView.window?.makeFirstResponder(self.textView)
      var r = entry.range
      if r.end < self.text.length { r.length += 1 }
      self.replace(r, with: "", selectAfter: NSRange(location: r.location, length: 0))
    }
    if bar.superview == nil { textView.addSubview(bar) }
    let size = bar.fittingSize
    bar.frame = CGRect(
      x: entry.grid.frame.minX, y: entry.grid.frame.minY - size.height - 4, width: size.width,
      height: size.height)
  }

  /// The caret moved into a (hidden) table: hand it to the grid.
  func enterTableIfNeeded(from old: NSRange) {
    guard mode == .rendered else { return }
    let sel = textView.selectedRange()
    guard sel.length == 0,
      let entry = overlays.tables.first(where: { NSLocationInRange(sel.location, $0.range) })
    else { return }
    let fromBelow = old.location > entry.range.location
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        entry.grid.focus(row: fromBelow ? entry.grid.model.rows.count - 1 : -1, col: 0)
      }
    }
  }

  func deleteTableRowAtCaret() {
    overlays.tables.first { $0.grid.focused != nil }?.grid.deleteFocusedRow()
  }

  func decorateTableMenu(_ menu: NSMenu, index: Int) {}

  // MARK: ⌥⌘T

  func insertTableWithPicker() {
    let caret = rectInView(for: NSRange(location: textView.selectedRange().location, length: 0))
    showTableSizePicker(rows: 2, cols: 3, near: caret) { [weak self] r, c in
      guard let self else { return }
      let t = TableModel(
        header: Array(repeating: "", count: c),
        rows: Array(repeating: Array(repeating: "", count: c), count: r),
        alignments: Array(repeating: .none, count: c))
      self.insertTable(t.serialized(eol: self.eol))
    }
  }

  private func insertTable(_ source: String) {
    let sel = textView.selectedRange()
    let line = text.lineRange(for: NSRange(location: sel.location, length: 0))
    let lineText = text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
    if lineText.isEmpty {
      var r = line
      while r.length > 0, [0x0A, 0x0D].contains(text.character(at: r.end - 1)) { r.length -= 1 }
      replace(r, with: source)
    } else {
      let at = line.end
      let endsWithNewline = at > 0 && [0x0A, 0x0D].contains(text.character(at: at - 1))
      replace(
        NSRange(location: at, length: 0),
        with: endsWithNewline ? eol + source + eol : eol + eol + source)
    }
    overlaysNeedUpdate()
  }

  func showTableSizePicker(
    rows: Int, cols: Int, near rect: CGRect, apply: @escaping (Int, Int) -> Void
  ) {
    let popover = NSPopover()
    popover.behavior = .transient
    popover.contentViewController = NSHostingController(
      rootView: TableSizePicker(rows: rows, columns: cols) { [weak popover] r, c in
        popover?.close()
        apply(r, c)
      })
    popover.show(relativeTo: rect.insetBy(dx: 0, dy: -2), of: textView, preferredEdge: .maxY)
  }
}

struct TableSizePicker: View {
  @State var rows: Int
  @State var columns: Int
  let onDone: (Int, Int) -> Void

  var body: some View {
    Form {
      Stepper("Rows: \(rows)", value: $rows, in: 1...100)
      Stepper("Columns: \(columns)", value: $columns, in: 1...30)
      HStack {
        Spacer()
        Button("OK") { onDone(rows, columns) }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(12)
    .frame(width: 200)
  }
}
