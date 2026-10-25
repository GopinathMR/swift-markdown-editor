import AppKit
import Observation

/// The host's handle on a `MarkdownEditor`: modes, outline, counts, commands, export.
@MainActor @Observable
public final class MarkdownEditorController {
  public var mode: EditorMode = .rendered {
    didSet { if mode != oldValue { coordinator?.setMode(mode) } }
  }
  public var isFocusMode = false {
    didSet { if isFocusMode != oldValue { coordinator?.focusModeChanged() } }
  }
  public var isTypewriterMode = false {
    didSet { if isTypewriterMode != oldValue { coordinator?.typewriterModeChanged() } }
  }
  public var zoom: Double = 1 {
    didSet {
      zoom = min(3, max(0.5, zoom))
      if zoom != oldValue { coordinator?.setZoom(CGFloat(zoom)) }
    }
  }
  public private(set) var outline: [OutlineItem] = []
  public private(set) var currentHeading: OutlineItem.ID?
  public private(set) var stats = DocumentStats()
  /// UTF-16 offsets into the markdown source.
  public private(set) var selectedRange = NSRange(location: 0, length: 0)
  public var isFindVisible = false

  @ObservationIgnored weak var coordinator: EditorCoordinator?
  @ObservationIgnored private var statsWork: DispatchWorkItem?
  @ObservationIgnored private var headings: [HeadingInfo] = []

  public init() {}

  // MARK: Fed by the coordinator

  func documentDidChange(_ model: DocumentModel, text: String) {
    if model.headings != headings {
      headings = model.headings
      outline = OutlineItem.tree(model.headings)
    }
    updateCurrentHeading()
    scheduleStats(text)
  }

  func selectionDidChange(_ range: NSRange, model: DocumentModel) {
    selectedRange = range
    updateCurrentHeading()
    if let c = coordinator { stats.applySelection(c.text.substring(with: range)) }
  }

  private func updateCurrentHeading() {
    let loc = selectedRange.location
    let id = headings.last(where: { $0.range.location <= loc })?.slug
    if id != currentHeading { currentHeading = id }
  }

  private func scheduleStats(_ text: String) {
    statsWork?.cancel()
    let wpm = coordinator?.preferences.readingSpeedWPM ?? 382
    let item = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        var s = DocumentStats.compute(text, model: self.coordinator?.model, wpm: wpm)
        s.selectionWords = self.stats.selectionWords
        s.selectionCharacters = self.stats.selectionCharacters
        self.stats = s
      }
    }
    statsWork = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
  }

  // MARK: Host API

  public func perform(_ command: EditorCommand) { coordinator?.perform(command) }

  public func canPerform(_ command: EditorCommand) -> Bool {
    coordinator?.canPerform(command) ?? false
  }

  /// Move the caret/selection (source offsets) and scroll it into view.
  public func setSelection(_ range: NSRange) {
    guard let c = coordinator else { return }
    let loc = min(range.location, c.storage.length)
    c.textView.setSelectedRange(
      NSRange(location: loc, length: min(range.length, c.storage.length - loc)))
    c.textView.scrollRangeToVisible(c.textView.selectedRange())
  }

  /// Scroll to a heading and put the caret there.
  public func reveal(_ heading: OutlineItem.ID) { coordinator?.reveal(slug: heading) }

  /// Open the find bar (with replace), optionally pre-filled.
  public func showFind(replace: Bool, query: String? = nil) {
    coordinator?.showFind(replace: replace)
    if let query { coordinator?.find.query = query }
  }

  /// Copy (or download) every image into `folder` and repoint the references (one undo step).
  public func copyAllImages(to folder: URL) async { await coordinator?.copyAllImages(to: folder) }

  /// Upload every local image through `EditorHooks.uploadImages` and use the returned URLs.
  public func uploadAllLocalImages() async { await coordinator?.uploadAllLocalImages() }

  public var availableExportFormats: [ExportFormat] { Exporter.availableFormats }

  public func export(_ format: ExportFormat, to url: URL, options: ExportOptions = .init())
    async throws
  {
    guard let c = coordinator else { return }
    try await Exporter(coordinator: c).export(format, to: url, options: options)
  }
}

public struct OutlineItem: Identifiable, Sendable, Equatable {
  public let id: String
  public let level: Int
  public let title: String
  public let number: String?
  public let range: NSRange
  public var children: [OutlineItem]

  static func tree(_ headings: [HeadingInfo]) -> [OutlineItem] {
    var roots: [OutlineItem] = []
    var stack: [OutlineItem] = []
    func pop() {
      let done = stack.removeLast()
      if stack.isEmpty { roots.append(done) } else { stack[stack.count - 1].children.append(done) }
    }
    for h in headings {
      while let top = stack.last, top.level >= h.level {
        _ = top
        pop()
      }
      stack.append(
        OutlineItem(
          id: h.slug, level: h.level, title: h.title, number: h.number, range: h.range, children: []
        ))
    }
    while !stack.isEmpty { pop() }
    return roots
  }
}
