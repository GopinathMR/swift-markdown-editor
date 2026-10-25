import AppKit
import Observation
import SwiftUI

/// Find/replace state. Matching runs on the markdown source; in rendered mode a match made
/// only of hidden syntax is skipped.
@MainActor @Observable
final class FindModel {
  var query = "" { didSet { if query != oldValue { refresh() } } }
  var replacement = ""
  var showReplace = false
  var caseSensitive = false { didSet { refresh() } }
  var wholeWord = false { didSet { refresh() } }
  var regex = false { didSet { refresh() } }
  private(set) var matches: [NSRange] = []
  private(set) var current: Int?
  private(set) var error: String?
  var focusToken = 0

  @ObservationIgnored weak var coordinator: EditorCoordinator?

  func expression() -> NSRegularExpression? {
    guard !query.isEmpty else { return nil }
    var pattern = regex ? query : NSRegularExpression.escapedPattern(for: query)
    if wholeWord { pattern = "\\b" + pattern + "\\b" }
    do {
      error = nil
      return try NSRegularExpression(
        pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive])
    } catch {
      self.error = "Invalid pattern"
      return nil
    }
  }

  func refresh() {
    guard let c = coordinator else { return }
    let text = c.text
    var found: [NSRange] = []
    if let re = expression() {
      for m in re.matches(in: text as String, range: NSRange(location: 0, length: text.length))
      where m.range.length > 0 {
        if c.mode == .rendered, Self.isAllHidden(m.range, in: c.storage) { continue }
        found.append(m.range)
      }
    }
    matches = found
    let caret = c.textView.selectedRange().location
    current = found.isEmpty ? nil : (found.firstIndex { $0.location >= caret } ?? 0)
    c.highlightFindMatches()
  }

  static func isAllHidden(_ r: NSRange, in storage: NSTextStorage) -> Bool {
    var all = true
    storage.enumerateAttribute(.mdHidden, in: r) { v, _, stop in
      if (v as? Bool) != true {
        all = false
        stop.pointee = true
      }
    }
    return all
  }

  func next(_ forward: Bool = true) {
    guard !matches.isEmpty else { return }
    let i =
      current.map { forward ? ($0 + 1) % matches.count : ($0 - 1 + matches.count) % matches.count }
      ?? 0
    current = i
    coordinator?.selectFindMatch(matches[i])
  }

  func replaceCurrent() {
    guard let c = coordinator, let i = current, i < matches.count else { return }
    let r = matches[i]
    let s = replacementString(for: r, in: c.text)
    c.replace(
      r, with: s, selectAfter: NSRange(location: r.location + (s as NSString).length, length: 0))
    refresh()
    next()
  }

  /// One edit over the span of all matches = one undo step and one reparse.
  func replaceAll() {
    guard let c = coordinator, let first = matches.first, let last = matches.last else { return }
    let text = c.text
    let span = NSRange(location: first.location, length: last.end - first.location)
    let out = NSMutableString()
    var cursor = span.location
    for m in matches {
      out.append(text.substring(with: NSRange(location: cursor, length: m.location - cursor)))
      out.append(replacementString(for: m, in: text))
      cursor = m.end
    }
    c.replace(span, with: out as String, selectAfter: NSRange(location: span.location, length: 0))
    refresh()
  }

  private func replacementString(for r: NSRange, in text: NSString) -> String {
    guard regex, let re = expression(), let m = re.firstMatch(in: text as String, range: r) else {
      return replacement
    }
    return re.replacementString(for: m, in: text as String, offset: 0, template: replacement)
  }
}

struct FindBar: View {
  @Bindable var model: FindModel
  @FocusState private var queryFocused: Bool

  var body: some View {
    VStack(spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Find", text: $model.query)
          .textFieldStyle(.roundedBorder)
          .focused($queryFocused)
          .onSubmit { model.next(!NSEvent.modifierFlags.contains(.shift)) }
          .accessibilityIdentifier("find-field")
        Text(status).font(.caption).foregroundStyle(
          model.error == nil ? Color.secondary : Color.red
        ).frame(minWidth: 70)
        Toggle("Aa", isOn: $model.caseSensitive).toggleStyle(.button).help("Match case")
        Toggle("W", isOn: $model.wholeWord).toggleStyle(.button).help("Whole word")
        Toggle(".*", isOn: $model.regex).toggleStyle(.button).help("Regular expression")
        Button {
          model.next(false)
        } label: {
          Image(systemName: "chevron.up")
        }
        Button {
          model.next(true)
        } label: {
          Image(systemName: "chevron.down")
        }
        Button {
          model.showReplace.toggle()
        } label: {
          Image(systemName: "arrow.2.squarepath")
        }.help("Replace")
        Button {
          model.coordinator?.hideFind()
        } label: {
          Image(systemName: "xmark")
        }
        .keyboardShortcut(.cancelAction)
      }
      if model.showReplace {
        HStack(spacing: 6) {
          Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
          TextField("Replace", text: $model.replacement).textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("replace-field")
          Button("Replace") { model.replaceCurrent() }.disabled(model.current == nil)
          Button("All") { model.replaceAll() }.disabled(model.matches.isEmpty)
        }
      }
    }
    .controlSize(.small)
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(.bar)
    .onAppear { queryFocused = true }
    .onChange(of: model.focusToken) { queryFocused = true }
  }

  private var status: String {
    if let e = model.error { return e }
    if model.query.isEmpty { return "" }
    if model.matches.isEmpty { return "No results" }
    return "\((model.current ?? 0) + 1) of \(model.matches.count)"
  }
}

/// Hosts the find bar above the scroll view.
final class EditorContainerView: NSView {
  let scrollView: NSScrollView
  private(set) var bar: NSView?

  init(scrollView: NSScrollView) {
    self.scrollView = scrollView
    super.init(frame: .zero)
    addSubview(scrollView)
  }

  required init?(coder: NSCoder) { fatalError() }

  func setBar(_ view: NSView?) {
    bar?.removeFromSuperview()
    bar = view
    if let view { addSubview(view) }
    needsLayout = true
  }

  override var isFlipped: Bool { true }

  override func layout() {
    super.layout()
    var top: CGFloat = 0
    if let bar {
      let h = bar.fittingSize.height
      bar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h)
      top = h
    }
    scrollView.frame = CGRect(
      x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
  }
}

extension EditorCoordinator {
  func showFind(replace: Bool) {
    find.coordinator = self
    find.showReplace = find.showReplace || replace
    let sel = textView.selectedRange()
    if sel.length > 0, sel.length < 200 { find.query = text.substring(with: sel) }
    if container.bar == nil {
      let host = NSHostingView(rootView: FindBar(model: find))
      container.setBar(host)
    }
    find.focusToken += 1
    controller?.isFindVisible = true
    find.refresh()
  }

  func hideFind() {
    container.setBar(nil)
    clearFindHighlights()
    controller?.isFindVisible = false
    textView.window?.makeFirstResponder(textView)
  }

  func highlightFindMatches() {
    clearFindHighlights()
    guard let lm = textView.textLayoutManager, let cs = lm.textContentManager else { return }
    for (i, r) in find.matches.enumerated() {
      guard let start = cs.location(cs.documentRange.location, offsetBy: r.location),
        let end = cs.location(start, offsetBy: r.length),
        let tr = NSTextRange(location: start, end: end)
      else { continue }
      let color =
        i == find.current ? NSColor.systemOrange : NSColor.systemYellow.withAlphaComponent(0.45)
      lm.addRenderingAttribute(.backgroundColor, value: color, for: tr)
    }
  }

  func clearFindHighlights() {
    guard let lm = textView.textLayoutManager else { return }
    lm.removeRenderingAttribute(.backgroundColor, for: lm.documentRange)
  }

  func selectFindMatch(_ r: NSRange) {
    textView.setSelectedRange(r)
    textView.scrollRangeToVisible(r)
    highlightFindMatches()
  }
}
