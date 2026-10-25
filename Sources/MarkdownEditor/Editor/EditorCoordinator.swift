import AppKit

/// Owns the text view, parser and styler, and keeps the host's string in sync.
@MainActor
final class EditorCoordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate,
  NSTextLayoutManagerDelegate
{
  let textView: EditorTextView
  let scrollView: NSScrollView
  let parser: MarkdownParser
  let styler: Styler
  let renders: RenderCache
  var hooks: EditorHooks
  var theme: EditorTheme
  var documentURL: URL? {
    didSet { styler.documentURL = documentURL }
  }
  weak var controller: MarkdownEditorController?
  var onTextChange: ((String) -> Void)?

  private(set) var model = DocumentModel()
  var preferences: EditorPreferences
  var zoom: CGFloat = 1
  var mode: EditorMode = .rendered

  private var pendingEdits: [(range: NSRange, delta: Int)] = []
  private var lastSelection = NSRange(location: 0, length: 0)
  private var restyleWorkItem: DispatchWorkItem?
  /// Set while we change the storage ourselves (external text, restyle) to skip delegate work.
  var isProgrammaticEdit = false

  var storage: NSTextStorage { textView.textStorage! }
  var text: NSString { storage.string as NSString }

  init(preferences: EditorPreferences, theme: EditorTheme, hooks: EditorHooks, documentURL: URL?) {
    self.preferences = preferences
    self.theme = theme
    self.hooks = hooks
    self.documentURL = documentURL
    parser = MarkdownParser(preferences: preferences)
    let renderBox = RendererBox()
    renders = RenderCache { req in await renderBox.render(req) }

    // TextKit 2 stack, built by hand so the text view is our subclass.
    let contentStorage = NSTextContentStorage()
    let layoutManager = NSTextLayoutManager()
    contentStorage.addTextLayoutManager(layoutManager)
    let container = NSTextContainer(
      size: CGSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = true
    layoutManager.textContainer = container
    textView = EditorTextView(
      frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
    scrollView = NSScrollView()

    let resolved = ResolvedTheme(style: theme.light, zoom: 1, isDark: false)
    styler = Styler(theme: resolved, preferences: preferences, renders: renders)
    styler.documentURL = documentURL
    styler.highlighter = CodeHighlighter()
    super.init()
    renderBox.coordinator = self

    textView.coordinator = self
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.minSize = .zero
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.allowsUndo = true
    textView.isRichText = false
    textView.importsGraphics = false
    textView.usesFindBar = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = true
    textView.isContinuousSpellCheckingEnabled = true
    textView.isAutomaticLinkDetectionEnabled = false
    textView.smartInsertDeleteEnabled = false
    textView.delegate = self
    textView.registerForDraggedTypes([.fileURL, .png, .tiff, .URL])
    storage.delegate = self
    layoutManager.delegate = self
    textView.onWidthChange = { [weak self] w in self?.containerWidthChanged(w) }
    renders.onReady = { [weak self] in self?.restyleAll() }

    scrollView.documentView = textView
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = true
    scrollView.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(boundsDidChange), name: NSView.boundsDidChangeNotification,
      object: scrollView.contentView)

    applyTheme()
  }

  // MARK: Text in and out

  func load(_ string: String) {
    isProgrammaticEdit = true
    storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: string)
    isProgrammaticEdit = false
    pendingEdits.removeAll()
    let result = parser.parse(text)
    adopt(result.model)
    restyleAll()
    textView.undoManager?.removeAllActions()
  }

  /// The host replaced the text. Swap only the differing middle so the caret and layout
  /// survive; old undo entries point at stale ranges, so they go.
  func setExternalText(_ new: String) {
    let old = storage.string
    guard old != new else { return }
    let a = old as NSString
    let b = new as NSString
    var prefix = 0
    let minLen = min(a.length, b.length)
    while prefix < minLen, a.character(at: prefix) == b.character(at: prefix) { prefix += 1 }
    var suffix = 0
    while suffix < minLen - prefix,
      a.character(at: a.length - 1 - suffix) == b.character(at: b.length - 1 - suffix)
    { suffix += 1 }
    let oldMid = NSRange(location: prefix, length: a.length - prefix - suffix)
    let newMid = b.substring(with: NSRange(location: prefix, length: b.length - prefix - suffix))
    var sel = textView.selectedRange()
    let delta = b.length - a.length
    isProgrammaticEdit = true
    storage.replaceCharacters(in: oldMid, with: newMid)
    isProgrammaticEdit = false
    if sel.location >= oldMid.end {
      sel.location += delta
    } else if sel.location > oldMid.location {
      sel = NSRange(location: oldMid.location + (newMid as NSString).length, length: 0)
    }
    textView.setSelectedRange(NSRange(location: min(sel.location, storage.length), length: 0))
    textView.undoManager?.removeAllActions()
    processPendingEdits()
  }

  // MARK: Delegates

  nonisolated func textStorage(
    _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
    range editedRange: NSRange,
    changeInLength delta: Int
  ) {
    guard editedMask.contains(.editedCharacters) else { return }
    MainActor.assumeIsolated {
      pendingEdits.append((editedRange, delta))
    }
  }

  func textDidChange(_ notification: Notification) {
    processPendingEdits()
    onTextChange?(storage.string)
  }

  func processPendingEdits() {
    guard !pendingEdits.isEmpty else { return }
    let edits = pendingEdits
    pendingEdits.removeAll()
    let result: MarkdownParser.Result
    if edits.count == 1 {
      result = parser.update(text, editedRange: edits[0].range, delta: edits[0].delta)
    } else {
      result = parser.parse(text)
    }
    let old = model
    adopt(result.model)
    var indices = result.changed
    let edited = edits.map(\.range).reduce(edits[0].range) { NSUnionRange($0, $1) }
    for loc in [edited.location, edited.end, textView.selectedRange().location] {
      if let i = model.entryIndex(at: loc) {
        indices.insert(i)
        if i > 0 { indices.insert(i - 1) }
        if i + 1 < model.entries.count { indices.insert(i + 1) }
      }
    }
    if old.linkRefs != model.linkRefs || old.footnoteNumbers != model.footnoteNumbers
      || Set(old.footnoteDefinitions.keys) != Set(model.footnoteDefinitions.keys)
    {
      indices = IndexSet(integersIn: 0..<model.entries.count)
    } else if old.headings != model.headings {
      for (i, e) in model.entries.enumerated() {
        if e.block.kind == .toc { indices.insert(i) }
        if theme.light.headingNumbering, case .heading = e.block.kind { indices.insert(i) }
      }
    }
    lastSelection = textView.selectedRange()
    styler.selection = lastSelection
    restyle(indices)
    controller?.documentDidChange(model, text: storage.string)
  }

  func textViewDidChangeSelection(_ notification: Notification) {
    guard pendingEdits.isEmpty, !isProgrammaticEdit else { return }
    let sel = textView.selectedRange()
    var indices = IndexSet()
    for loc in [lastSelection.location, lastSelection.end, sel.location, sel.end] {
      if let i = model.entryIndex(at: loc) { indices.insert(i) }
      // The caret at an entry's very start also touches the previous entry's end.
      if let i = model.entryIndex(at: max(0, loc - 1)) { indices.insert(i) }
    }
    lastSelection = sel
    styler.selection = sel
    restyle(indices)
    controller?.selectionDidChange(sel, model: model)
    selectionDidChangeHooks()
  }

  nonisolated func textLayoutManager(
    _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation,
    in textElement: NSTextElement
  ) -> NSTextLayoutFragment {
    MarkdownLayoutFragment(textElement: textElement, range: textElement.elementRange)
  }

  // MARK: Styling

  private func adopt(_ m: DocumentModel) {
    model = m
    styler.model = m
  }

  func restyle(_ indices: IndexSet) {
    guard !indices.isEmpty else { return }
    isProgrammaticEdit = true
    styler.resetOverlayRecords()
    styler.apply(indices, to: storage)
    isProgrammaticEdit = false
    textView.typingAttributes = styler.baseAttributes()
    overlaysNeedUpdate()
  }

  func restyleAll() {
    styler.selection = textView.selectedRange()
    if model.entries.isEmpty {
      restyle(IndexSet(integer: 0))
    } else {
      restyle(IndexSet(integersIn: 0..<model.entries.count))
    }
  }

  func setPreferences(_ p: EditorPreferences) {
    guard p != preferences else { return }
    preferences = p
    parser.preferences = p
    styler.preferences = p
    adopt(parser.parse(text).model)
    restyleAll()
  }

  func setTheme(_ t: EditorTheme) {
    guard t != theme else { return }
    theme = t
    applyTheme()
  }

  func setZoom(_ z: CGFloat) {
    guard z != zoom else { return }
    zoom = z
    applyTheme()
  }

  func setMode(_ m: EditorMode) {
    guard m != mode else { return }
    mode = m
    styler.mode = m
    restyleAll()
    textView.scrollRangeToVisible(textView.selectedRange())
  }

  var isDark: Bool {
    textView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
  }

  func appearanceDidChange() { applyTheme() }

  func applyTheme() {
    let style = theme.style(dark: isDark)
    let resolved = ResolvedTheme(style: style, zoom: zoom, isDark: isDark)
    styler.theme = resolved
    textView.maxContentWidth = style.maxWidth.map { $0 * zoom }
    textView.backgroundColor = resolved.background
    scrollView.backgroundColor = resolved.background
    textView.insertionPointColor = resolved.text
    textView.selectedTextAttributes = [.backgroundColor: resolved.selection]
    textView.updateInsets()
    styler.containerWidth = textView.textContainer?.size.width ?? 700
    restyleAll()
  }

  private func containerWidthChanged(_ w: CGFloat) {
    styler.containerWidth = w
    // Renders scale with width; restyle once the resize settles.
    restyleWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.restyleAll() } }
    restyleWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
  }

  @objc private func boundsDidChange() { viewportDidScroll() }

  // MARK: Edits through the text view (undoable)

  /// Replace `range` with `string` as one undoable user edit.
  @discardableResult
  func replace(_ range: NSRange, with string: String, selectAfter: NSRange? = nil) -> Bool {
    guard textView.shouldChangeText(in: range, replacementString: string) else { return false }
    storage.replaceCharacters(in: range, with: string)
    textView.didChangeText()
    if let s = selectAfter { textView.setSelectedRange(s) }
    return true
  }
}

/// Late-bound renderer so the cache can exist before the coordinator finishes init.
@MainActor
final class RendererBox {
  weak var coordinator: EditorCoordinator?
  func render(_ req: RenderRequest) async -> RenderResult {
    await Renderers.render(req, darkMode: coordinator?.isDark ?? false)
  }
}
