import AppKit
import WebKit

/// Renders Mermaid, flowchart.js and js-sequence diagrams with the bundled JS in one hidden,
/// offscreen WKWebView. Render-only: it never shows content to edit. Renders run one at a
/// time; each returns the SVG (for HTML export) and a snapshot image (for the editor).
@MainActor
final class DiagramRenderer: NSObject, WKNavigationDelegate {
  static let shared = DiagramRenderer()

  private var web: WKWebView?
  private var window: NSWindow?
  private var loaded: Task<Bool, Never>?
  private var loadContinuation: CheckedContinuation<Bool, Never>?
  private var tail: Task<Void, Never>?

  private func ensureLoaded() async -> Bool {
    if let loaded { return await loaded.value }
    let task = Task<Bool, Never> { @MainActor in
      guard
        let page = Bundle.module.url(
          forResource: "render", withExtension: "html", subdirectory: "Resources/diagrams")
      else { return false }
      let config = WKWebViewConfiguration()
      config.websiteDataStore = .nonPersistent()
      let web = WKWebView(
        frame: CGRect(x: 0, y: 0, width: 1600, height: 1200), configuration: config)
      web.setValue(false, forKey: "drawsBackground")
      web.navigationDelegate = self
      // Offscreen, invisible and inert; WebKit only paints views that are in a window.
      let window = NSWindow(
        contentRect: CGRect(x: -30000, y: -30000, width: 1600, height: 1200),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.alphaValue = 0
      window.ignoresMouseEvents = true
      window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
      window.contentView = web
      window.orderBack(nil)
      self.web = web
      self.window = window
      return await withCheckedContinuation { c in
        self.loadContinuation = c
        web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
      }
    }
    loaded = task
    return await task.value
  }

  nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    MainActor.assumeIsolated {
      loadContinuation?.resume(returning: true)
      loadContinuation = nil
    }
  }

  nonisolated func webView(
    _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
  ) {
    MainActor.assumeIsolated {
      loadContinuation?.resume(returning: false)
      loadContinuation = nil
    }
  }

  func render(_ kind: DiagramKind, source: String, dark: Bool) async -> RenderResult {
    // Serialise: one diagram in the page at a time.
    let previous = tail
    let task = Task<RenderResult, Never> { @MainActor in
      await previous?.value
      return await self.renderNow(kind, source: source, dark: dark)
    }
    tail = Task { _ = await task.value }
    return await task.value
  }

  private func renderNow(_ kind: DiagramKind, source: String, dark: Bool) async -> RenderResult {
    guard await ensureLoaded(), let web else {
      return RenderResult(image: nil, size: .zero, error: "Diagram renderer unavailable")
    }
    do {
      let value = try await web.callAsyncJavaScript(
        "return await renderDiagram(kind, source, dark);",
        arguments: ["kind": kind.rawValue, "source": source, "dark": dark], contentWorld: .page)
      guard let dict = value as? [String: Any], let svg = dict["svg"] as? String,
        let w = (dict["width"] as? NSNumber)?.doubleValue,
        let h = (dict["height"] as? NSNumber)?.doubleValue, w > 0, h > 0
      else { return RenderResult(image: nil, size: .zero, error: "Empty diagram") }
      let size = CGSize(width: w, height: h)
      if web.frame.width < size.width || web.frame.height < size.height {
        let big = CGSize(
          width: max(web.frame.width, size.width), height: max(web.frame.height, size.height))
        window?.setContentSize(big)
        web.frame = CGRect(origin: .zero, size: big)
      }
      let config = WKSnapshotConfiguration()
      config.rect = CGRect(origin: .zero, size: size)
      config.afterScreenUpdates = true
      let image = try await web.takeSnapshot(configuration: config)
      return RenderResult(image: image, size: size, svg: svg)
    } catch {
      let message =
        (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
        ?? error.localizedDescription
      return RenderResult(
        image: nil, size: .zero, error: message.components(separatedBy: "\n").first ?? message)
    }
  }
}
