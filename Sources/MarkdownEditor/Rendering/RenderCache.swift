import AppKit

enum RenderRequest: Hashable, Sendable {
  case math(latex: String, display: Bool, dark: Bool, fontSize: CGFloat, number: String?)
  case diagram(DiagramKind, source: String, dark: Bool)
  case image(URL)
  case html(String, width: CGFloat, dark: Bool)
}

struct RenderResult {
  var image: NSImage?
  var size: CGSize
  /// Distance from the image bottom to the text baseline (inline math).
  var descent: CGFloat = 0
  var error: String?
  /// SVG for HTML export (diagrams).
  var svg: String?
}

/// Renders off the hot path and caches by request. The styler asks synchronously; a miss
/// schedules the work and the editor restyles when `onReady` fires.
@MainActor
final class RenderCache {
  typealias Renderer = @MainActor (RenderRequest) async -> RenderResult

  var onReady: (() -> Void)?
  private var results: [RenderRequest: RenderResult] = [:]
  private var pending: Set<RenderRequest> = []
  private var order: [RenderRequest] = []
  private let capacity = 600
  private var readyScheduled = false
  let renderer: Renderer

  init(renderer: @escaping Renderer) {
    self.renderer = renderer
  }

  func peek(_ request: RenderRequest) -> RenderResult? { results[request] }

  func result(for request: RenderRequest) -> RenderResult? {
    if let r = results[request] { return r }
    if !pending.contains(request) {
      pending.insert(request)
      Task { [weak self] in
        guard let self else { return }
        let r = await self.renderer(request)
        self.store(r, for: request)
      }
    }
    return nil
  }

  private var lastByKey: [Int: RenderResult] = [:]
  private var debounce: [Int: DispatchWorkItem] = [:]

  /// For a block being edited: render only after typing pauses, showing the block's last
  /// render meanwhile so the preview doesn't flicker on every keystroke.
  func result(for request: RenderRequest, debounceKey key: Int) -> RenderResult? {
    if let r = results[request] {
      lastByKey[key] = r
      return r
    }
    debounce[key]?.cancel()
    let item = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated { _ = self?.result(for: request) }
    }
    debounce[key] = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    return lastByKey[key]
  }

  /// Waits for a render (export needs every image, not placeholders).
  func resolve(_ request: RenderRequest) async -> RenderResult {
    if let r = results[request] { return r }
    let r = await renderer(request)
    store(r, for: request)
    return r
  }

  private func store(_ r: RenderResult, for request: RenderRequest) {
    pending.remove(request)
    results[request] = r
    order.append(request)
    if order.count > capacity {
      let drop = order.removeFirst()
      results[drop] = nil
    }
    // Coalesce a burst of finished renders into one restyle.
    guard !readyScheduled else { return }
    readyScheduled = true
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        self?.readyScheduled = false
        self?.onReady?()
      }
    }
  }

  func invalidate(where predicate: (RenderRequest) -> Bool) {
    for key in results.keys where predicate(key) { results[key] = nil }
  }
}

extension RenderCache {
  /// A finished render, without scheduling one (clipboard: use what's ready).
  func cached(_ request: RenderRequest) -> RenderResult? { peek(request) }
}
