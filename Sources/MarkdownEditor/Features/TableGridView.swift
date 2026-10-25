import AppKit

/// The live, editable grid drawn over a table's reserved space. Every change goes back to
/// the coordinator as a new `TableModel`, which rewrites only that table's source lines.
@MainActor
final class TableGridView: NSView, NSTextFieldDelegate {
  enum Exit { case above, below }

  private(set) var model: TableModel
  private var metrics: TableLayout.Metrics
  private var theme: ResolvedTheme
  private var fields: [[NSTextField]] = []  // [row][col], row 0 = header
  var onChange: ((TableModel) -> Void)?
  var onExit: ((Exit) -> Void)?
  var onFocusChange: ((Bool) -> Void)?
  private(set) var focused: (row: Int, col: Int)?  // row -1 = header

  init(model: TableModel, theme: ResolvedTheme, width: CGFloat) {
    self.model = model
    self.theme = theme
    metrics = TableLayout.metrics(model, theme: theme, width: width)
    super.init(frame: CGRect(origin: .zero, size: metrics.size))
    rebuild()
    setAccessibilityRole(.table)
    setAccessibilityLabel("Table")
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { true }

  /// Adopt a model from the source; leave the cell being typed in alone.
  func update(model new: TableModel, theme: ResolvedTheme, width: CGFloat) {
    let shapeChanged = new.columnCount != model.columnCount || new.rows.count != model.rows.count
    let themeChanged = theme !== self.theme
    model = new
    self.theme = theme
    metrics = TableLayout.metrics(new, theme: theme, width: width)
    if shapeChanged || themeChanged || fields.isEmpty {
      let keep = focused
      rebuild()
      if let keep {
        focus(row: min(keep.row, model.rows.count - 1), col: min(keep.col, model.columnCount - 1))
      }
    } else {
      for r in 0...model.rows.count {
        for c in 0..<model.columnCount {
          let f = fields[r][c]
          let v = model[r - 1, c]
          if f.currentEditor() == nil, f.stringValue != v { f.stringValue = v }
          f.alignment = Self.alignment(model.alignments[c])
        }
      }
      layoutFields()
    }
    setFrameSize(metrics.size)
    needsDisplay = true
  }

  private static func alignment(_ a: ColumnAlignment) -> NSTextAlignment {
    switch a {
    case .center: return .center
    case .right: return .right
    default: return .left
    }
  }

  private func rebuild() {
    for f in fields.flatMap({ $0 }) { f.removeFromSuperview() }
    fields = (0...model.rows.count).map { r in
      (0..<model.columnCount).map { c in
        let f = NSTextField(string: model[r - 1, c])
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.isEditable = true
        f.usesSingleLineMode = false
        f.cell?.wraps = true
        f.cell?.isScrollable = false
        f.lineBreakMode = .byWordWrapping
        f.font = r == 0 ? theme.font(bold: true, italic: false) : theme.body
        f.textColor = theme.text
        f.alignment = Self.alignment(model.alignments[c])
        f.delegate = self
        f.tag = r * 1000 + c
        f.setAccessibilityLabel(r == 0 ? "Header, column \(c + 1)" : "Row \(r), column \(c + 1)")
        addSubview(f)
        return f
      }
    }
    layoutFields()
  }

  private func layoutFields() {
    var y: CGFloat = 0
    for (r, row) in fields.enumerated() where r < metrics.rowHeights.count {
      var x: CGFloat = 0
      for (c, f) in row.enumerated() where c < metrics.columnWidths.count {
        let w = metrics.columnWidths[c]
        f.frame = CGRect(
          x: x + TableLayout.padX - 2, y: y + TableLayout.padY - 1,
          width: w - 2 * TableLayout.padX + 4,
          height: metrics.rowHeights[r] - 2 * TableLayout.padY + 2)
        x += w
      }
      y += metrics.rowHeights[r]
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    let size = metrics.size
    theme.tableHeader.setFill()
    NSRect(x: 0, y: 0, width: size.width - 1, height: metrics.rowHeights.first ?? 0).fill()
    if let f = focused {
      NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
      cellRect(row: f.row + 1, col: f.col).fill()
    }
    theme.tableBorder.setStroke()
    let path = NSBezierPath()
    // Horizontal lines.
    var yy: CGFloat = 0.5
    path.move(to: CGPoint(x: 0, y: yy))
    path.line(to: CGPoint(x: size.width - 1, y: yy))
    for h in metrics.rowHeights {
      yy += h
      path.move(to: CGPoint(x: 0, y: yy))
      path.line(to: CGPoint(x: size.width - 1, y: yy))
    }
    // Vertical lines.
    var xx: CGFloat = 0.5
    path.move(to: CGPoint(x: xx, y: 0))
    path.line(to: CGPoint(x: xx, y: size.height - 1))
    for w in metrics.columnWidths {
      xx += w
      path.move(to: CGPoint(x: xx, y: 0))
      path.line(to: CGPoint(x: xx, y: size.height - 1))
    }
    path.lineWidth = 1
    path.stroke()
  }

  private func cellRect(row: Int, col: Int) -> CGRect {
    let x = metrics.columnWidths.prefix(col).reduce(0, +)
    let y = metrics.rowHeights.prefix(row).reduce(0, +)
    return CGRect(x: x, y: y, width: metrics.columnWidths[col], height: metrics.rowHeights[row])
  }

  // MARK: Focus

  func focus(row: Int, col: Int) {
    let r = max(-1, min(row, model.rows.count - 1))
    let c = max(0, min(col, model.columnCount - 1))
    let f = fields[r + 1][c]
    window?.makeFirstResponder(f)
    f.currentEditor()?.selectedRange = NSRange(
      location: (f.stringValue as NSString).length, length: 0)
    focused = (r, c)
    needsDisplay = true
  }

  var hasFocus: Bool { fields.flatMap { $0 }.contains { $0.currentEditor() != nil } }

  func controlTextDidBeginEditing(_ obj: Notification) {
    guard let f = obj.object as? NSTextField else { return }
    focused = (f.tag / 1000 - 1, f.tag % 1000)
    needsDisplay = true
    onFocusChange?(true)
  }

  func controlTextDidEndEditing(_ obj: Notification) {
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        guard let self, !self.hasFocus else { return }
        self.focused = nil
        self.needsDisplay = true
        self.onFocusChange?(false)
      }
    }
  }

  func controlTextDidChange(_ obj: Notification) {
    guard let f = obj.object as? NSTextField else { return }
    let r = f.tag / 1000 - 1
    let c = f.tag % 1000
    model[r, c] = f.stringValue
    onChange?(model)
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
    guard let (r, c) = focused else { return false }
    switch sel {
    case #selector(NSResponder.insertTab(_:)):
      if c + 1 < model.columnCount {
        focus(row: r, col: c + 1)
      } else if r + 1 < model.rows.count {
        focus(row: r + 1, col: 0)
      } else {
        apply { $0.insertRow(at: $0.rows.count) }
        focus(row: model.rows.count - 1, col: 0)
      }
      return true
    case #selector(NSResponder.insertBacktab(_:)):
      if c > 0 {
        focus(row: r, col: c - 1)
      } else if r > -1 {
        focus(row: r - 1, col: model.columnCount - 1)
      }
      return true
    case #selector(NSResponder.insertNewline(_:)):
      if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
        apply { $0.insertRow(at: r + 1) }
        focus(row: r + 1, col: c)
      } else if r + 1 < model.rows.count {
        focus(row: r + 1, col: c)
      } else {
        onExit?(.below)
      }
      return true
    case #selector(NSResponder.moveUp(_:)):
      if r == -1 { onExit?(.above) } else { focus(row: r - 1, col: c) }
      return true
    case #selector(NSResponder.moveDown(_:)):
      if r + 1 >= model.rows.count { onExit?(.below) } else { focus(row: r + 1, col: c) }
      return true
    case #selector(NSResponder.cancelOperation(_:)):
      onExit?(.below)
      return true
    default:
      return false
    }
  }

  // MARK: Edits

  func apply(_ change: (inout TableModel) -> Void) {
    var m = model
    change(&m)
    guard m != model else { return }
    onChange?(m)
  }

  func setAlignment(_ a: ColumnAlignment) {
    guard let c = focused?.col else { return }
    apply { $0.alignments[c] = a }
  }

  func deleteFocusedRow() {
    guard let r = focused?.row, r >= 0 else { return }
    apply { $0.deleteRow(at: r) }
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    let p = convert(event.locationInWindow, from: nil)
    var col = 0
    var x: CGFloat = 0
    for (i, w) in metrics.columnWidths.enumerated() {
      if p.x >= x { col = i }
      x += w
    }
    var row = -1
    var y: CGFloat = 0
    for (i, h) in metrics.rowHeights.enumerated() {
      if p.y >= y { row = i - 1 }
      y += h
    }
    let menu = NSMenu()
    func item(_ title: String, _ change: @escaping (inout TableModel) -> Void) {
      let i = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
      i.target = self
      i.representedObject = MenuChange(change)
      menu.addItem(i)
    }
    item("Insert Row Above") { $0.insertRow(at: max(0, row)) }
    item("Insert Row Below") { $0.insertRow(at: row + 1) }
    item("Insert Column Left") { $0.insertColumn(at: col) }
    item("Insert Column Right") { $0.insertColumn(at: col + 1) }
    menu.addItem(.separator())
    item("Move Row Up") { $0.moveRow(from: row, to: row - 1) }
    item("Move Row Down") { $0.moveRow(from: row, to: row + 1) }
    item("Move Column Left") { $0.moveColumn(from: col, to: col - 1) }
    item("Move Column Right") { $0.moveColumn(from: col, to: col + 1) }
    menu.addItem(.separator())
    item("Align Left") { $0.alignments[col] = .left }
    item("Align Center") { $0.alignments[col] = .center }
    item("Align Right") { $0.alignments[col] = .right }
    menu.addItem(.separator())
    if row >= 0 { item("Delete Row") { $0.deleteRow(at: row) } }
    item("Delete Column") { $0.deleteColumn(at: col) }
    return menu
  }

  @objc private func menuAction(_ sender: NSMenuItem) {
    guard let c = sender.representedObject as? MenuChange else { return }
    apply(c.change)
  }

  private final class MenuChange: NSObject {
    let change: (inout TableModel) -> Void
    init(_ c: @escaping (inout TableModel) -> Void) { change = c }
  }
}

/// Floating bar over a focused table: size, alignment, delete.
@MainActor
final class TableToolbar: NSStackView {
  weak var grid: TableGridView?
  var onResize: (() -> Void)?
  var onDelete: (() -> Void)?

  init() {
    super.init(frame: .zero)
    orientation = .horizontal
    spacing = 2
    edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
    wantsLayer = true
    layer?.cornerRadius = 6
    layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    layer?.borderColor = NSColor.separatorColor.cgColor
    layer?.borderWidth = 1
    func button(_ symbol: String, _ help: String, _ action: Selector) -> NSButton {
      let b = NSButton(
        image: NSImage(systemSymbolName: symbol, accessibilityDescription: help)!, target: self,
        action: action)
      b.isBordered = false
      b.toolTip = help
      b.setAccessibilityLabel(help)
      return b
    }
    addArrangedSubview(button("tablecells", "Resize table", #selector(resizeTable)))
    addArrangedSubview(button("text.alignleft", "Align left", #selector(alignLeft)))
    addArrangedSubview(button("text.aligncenter", "Align center", #selector(alignCenter)))
    addArrangedSubview(button("text.alignright", "Align right", #selector(alignRight)))
    addArrangedSubview(button("trash", "Delete table", #selector(delete)))
  }

  required init(coder: NSCoder) { fatalError() }

  @objc private func resizeTable() { onResize?() }
  @objc private func alignLeft() { grid?.setAlignment(.left) }
  @objc private func alignCenter() { grid?.setAlignment(.center) }
  @objc private func alignRight() { grid?.setAlignment(.right) }
  @objc private func delete() { onDelete?() }
}
