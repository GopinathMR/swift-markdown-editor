import AppKit
import PDFKit
import WebKit

public enum PandocFormat: String, CaseIterable, Sendable {
  case docx, odt, rtf, epub, latex, mediawiki, rst, textile, opml, markdown
  var fileExtension: String {
    switch self {
    case .latex: return "tex"
    case .mediawiki: return "wiki"
    case .markdown: return "md"
    default: return rawValue
    }
  }
}

public enum ExportFormat: Hashable, Sendable {
  case html(styled: Bool)
  case pdf, png
  case pandoc(PandocFormat)

  public var fileExtension: String {
    switch self {
    case .html: return "html"
    case .pdf: return "pdf"
    case .png: return "png"
    case .pandoc(let f): return f.fileExtension
    }
  }
}

public struct ExportOptions: Sendable {
  public enum Paper: Sendable, Equatable {
    case a4, a5, letter
    case custom(CGSize)
    var size: CGSize {
      switch self {
      case .a4: return CGSize(width: 595, height: 842)
      case .a5: return CGSize(width: 420, height: 595)
      case .letter: return CGSize(width: 612, height: 792)
      case .custom(let s): return s
      }
    }
  }

  /// Theme for the output; `nil` = the editor's light style.
  public var theme: ThemeStyle?
  public var includeOutline = false
  /// Extra HTML for `<head>` / end of `<body>`. `${title}`, `${author}`, `${today}` … expand.
  public var appendHead = ""
  public var appendBody = ""
  public var paper: Paper = .a4
  public var margins = NSEdgeInsets(top: 54, left: 54, bottom: 54, right: 54)
  public var pageBreakBeforeH1 = false
  /// PDF header/footer; `${pageNo}`, `${pageCount}`, `${title}`, `${author}` expand.
  public var header: String?
  public var footer: String? = "${pageNo} / ${pageCount}"
  public var imageWidth: CGFloat = 640
  /// Extra pandoc arguments.
  public var pandocArguments: [String] = []

  public init() {}
}

public enum ExportError: Error, Sendable, Equatable {
  case pandocMissing
  case pandoc(status: Int32, stderr: String)
  case write(String)
  case render(String)
}

@MainActor
struct Exporter {
  let coordinator: EditorCoordinator

  nonisolated static var pandocURL: URL? {
    let candidates =
      ["/opt/homebrew/bin/pandoc", "/usr/local/bin/pandoc", "/usr/bin/pandoc"]
      + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map {
        "\($0)/pandoc"
      }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(
      URL.init(fileURLWithPath:))
  }

  static var availableFormats: [ExportFormat] {
    [.html(styled: true), .html(styled: false), .pdf, .png]
      + (pandocURL == nil ? [] : PandocFormat.allCases.map { .pandoc($0) })
  }

  // MARK: Variables

  /// Front matter (when allowed) overrides the options; `${…}` expands everywhere.
  func variables(_ options: ExportOptions) -> [String: String] {
    let c = coordinator
    var v: [String: String] = [:]
    let name = c.documentURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    v["title"] = c.model.headings.first?.title ?? name
    v["currentFileName"] = name
    v["currentFileFullName"] = c.documentURL?.lastPathComponent ?? name
    v["currentPath"] = c.documentURL?.path ?? ""
    v["currentFolder"] = c.documentURL?.deletingLastPathComponent().path ?? ""
    let f = DateFormatter()
    f.dateStyle = .medium
    v["today"] = f.string(from: Date())
    if let fm = c.model.frontMatter {
      let values = FrontMatter.parse(fm).values
      for (k, _) in values { if let s = FrontMatter.value(k, in: values) { v[k] = s } }
    }
    return v
  }

  func expand(_ s: String, _ vars: [String: String]) -> String {
    var out = s
    for m in s.matches(of: #/\$\{([A-Za-z0-9_.-]+)\}/#).reversed() {
      if let value = vars[String(m.1)] { out.replaceSubrange(m.range, with: value) }
    }
    return out
  }

  private func overridden(_ options: ExportOptions, _ vars: [String: String]) -> ExportOptions {
    guard coordinator.preferences.frontMatterOverridesExport else { return options }
    var o = options
    if let h = vars["header"] { o.header = h }
    if let f = vars["footer"] { o.footer = f }
    if let a = vars["append-head"] { o.appendHead += a }
    if let a = vars["append-body"] { o.appendBody += a }
    return o
  }

  // MARK: HTML

  func html(styled: Bool, options: ExportOptions) async -> String {
    let c = coordinator
    let style = options.theme ?? c.theme.light
    let vars = variables(options)
    let opts = overridden(options, vars)
    let fontSize = style.baseSize
    let renderer = HTMLRenderer(
      text: c.text, model: c.model, preferences: c.preferences,
      render: { [renders = c.renders] in renders.cached($0) },
      resolveURL: { [styler = c.styler] in styler.resolveURL($0) }, embedImages: true, dark: false)
    for req in renderer.requests(fontSize: fontSize) { _ = await c.renders.resolve(req) }
    var outline = ""
    if opts.includeOutline, !c.model.headings.isEmpty {
      let minLevel = c.model.headings.map(\.level).min() ?? 1
      outline =
        "<nav class=\"outline\"><ul>"
        + c.model.headings.map {
          "<li class=\"toc-h\($0.level - minLevel + 1)\"><a href=\"#\(renderer.esc($0.slug))\">\(renderer.esc($0.title))</a></li>"
        }.joined()
        + "</ul></nav>\n"
    }
    var css = styled ? style.css() : ""
    if opts.pageBreakBeforeH1 { css += "\nh1:not(:first-of-type) { page-break-before: always; }" }
    let title = renderer.esc(vars["title"] ?? "")
    return """
      <!doctype html>
      <html><head><meta charset="utf-8"><title>\(title)</title>
      \(css.isEmpty ? "" : "<style>\n\(css)\n</style>")
      \(expand(opts.appendHead, vars))
      </head><body>
      \(outline)\(renderer.body(fontSize: fontSize))\(expand(opts.appendBody, vars))
      </body></html>
      """
  }

  // MARK: Export

  func export(_ format: ExportFormat, to url: URL, options: ExportOptions) async throws {
    switch format {
    case .html(let styled):
      try write(Data(await html(styled: styled, options: options).utf8), to: url)
    case .pdf:
      let page = await html(styled: true, options: options)
      let raw = try await WebExport.pdf(
        html: page, base: coordinator.documentURL?.deletingLastPathComponent(), options: options)
      let vars = variables(options)
      try write(try stamp(raw, options: overridden(options, vars), vars: vars), to: url)
    case .png:
      let page = await html(styled: true, options: options)
      let png = try await WebExport.png(
        html: page, base: coordinator.documentURL?.deletingLastPathComponent(),
        width: options.imageWidth)
      try write(png, to: url)
    case .pandoc(let f):
      try pandoc(f, to: url, options: options)
    }
  }

  private func write(_ data: Data, to url: URL) throws {
    do { try data.write(to: url, options: .atomic) } catch {
      throw ExportError.write(error.localizedDescription)
    }
  }

  /// Header/footer per page and document metadata, drawn over the printed pages.
  private func stamp(_ pdf: Data, options: ExportOptions, vars: [String: String]) throws -> Data {
    guard let doc = PDFDocument(data: pdf) else {
      throw ExportError.render("PDF generation failed")
    }
    let out = NSMutableData()
    var info: [CFString: Any] = [kCGPDFContextCreator: "swift-markdown-editor"]
    if let t = vars["title"] { info[kCGPDFContextTitle] = t }
    if let a = vars["author"] { info[kCGPDFContextAuthor] = a }
    if let s = vars["subject"] { info[kCGPDFContextSubject] = s }
    if let k = vars["keywords"] ?? vars["tags"] { info[kCGPDFContextKeywords] = k }
    guard let consumer = CGDataConsumer(data: out as CFMutableData),
      let ctx = CGContext(consumer: consumer, mediaBox: nil, info as CFDictionary)
    else { throw ExportError.render("PDF generation failed") }
    let count = doc.pageCount
    for i in 0..<count {
      guard let page = doc.page(at: i) else { continue }
      var box = page.bounds(for: .mediaBox)
      ctx.beginPage(mediaBox: &box)
      page.draw(with: .mediaBox, to: ctx)
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
      var pageVars = vars
      pageVars["pageNo"] = "\(i + 1)"
      pageVars["pageCount"] = "\(count)"
      pageVars["totalPages"] = "\(count)"
      let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.gray,
      ]
      if let h = options.header, !h.isEmpty {
        let s = NSAttributedString(string: expand(h, pageVars), attributes: attrs)
        s.draw(
          at: CGPoint(
            x: (box.width - s.size().width) / 2, y: box.height - options.margins.top / 2 - 4))
      }
      if let f = options.footer, !f.isEmpty {
        let s = NSAttributedString(string: expand(f, pageVars), attributes: attrs)
        s.draw(at: CGPoint(x: (box.width - s.size().width) / 2, y: options.margins.bottom / 2 - 4))
      }
      NSGraphicsContext.restoreGraphicsState()
      ctx.endPage()
    }
    ctx.closePDF()
    return out as Data
  }

  private func pandoc(_ f: PandocFormat, to url: URL, options: ExportOptions) throws {
    guard let exe = Self.pandocURL else { throw ExportError.pandocMissing }
    let p = Process()
    p.executableURL = exe
    p.arguments =
      [
        "-f",
        "markdown+tex_math_dollars+footnotes+pipe_tables+task_lists+yaml_metadata_block+mark+superscript+subscript",
        "-t", f.rawValue, "-s", "-o", url.path,
      ]
      + options.pandocArguments
    if let dir = coordinator.documentURL?.deletingLastPathComponent() {
      p.currentDirectoryURL = dir
      p.arguments! += ["--resource-path", dir.path]
    }
    let input = Pipe()
    let err = Pipe()
    p.standardInput = input
    p.standardError = err
    p.standardOutput = FileHandle.nullDevice
    do { try p.run() } catch {
      throw ExportError.pandoc(status: -1, stderr: error.localizedDescription)
    }
    input.fileHandleForWriting.write(Data((coordinator.storage.string).utf8))
    try? input.fileHandleForWriting.close()
    p.waitUntilExit()
    let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    guard p.terminationStatus == 0 else {
      throw ExportError.pandoc(status: p.terminationStatus, stderr: stderr)
    }
  }
}

/// Offscreen WebKit for export only: print HTML to PDF, snapshot it to PNG.
@MainActor
final class WebExport: NSObject, WKNavigationDelegate {
  private let web: WKWebView
  private let window: NSWindow
  private var loaded: CheckedContinuation<Void, Error>?

  private init(width: CGFloat) {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    web = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: 1000), configuration: config)
    window = NSWindow(
      contentRect: CGRect(x: -30000, y: -30000, width: width, height: 1000),
      styleMask: [.borderless], backing: .buffered, defer: false)
    super.init()
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.contentView = web
    window.orderBack(nil)
    web.navigationDelegate = self
  }

  private func load(_ html: String, base: URL?) async throws {
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
      loaded = c
      web.loadHTMLString(html, baseURL: base)
    }
  }

  nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    MainActor.assumeIsolated {
      loaded?.resume()
      loaded = nil
    }
  }

  nonisolated func webView(
    _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
  ) {
    MainActor.assumeIsolated {
      loaded?.resume(throwing: ExportError.render(error.localizedDescription))
      loaded = nil
    }
  }

  static func pdf(html: String, base: URL?, options: ExportOptions) async throws -> Data {
    let paper = options.paper.size
    let session = WebExport(width: paper.width)
    defer { session.window.close() }
    try await session.load(html, base: base)
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".pdf")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let info = NSPrintInfo()
    info.paperSize = paper
    info.topMargin = options.margins.top
    info.bottomMargin = options.margins.bottom
    info.leftMargin = options.margins.left
    info.rightMargin = options.margins.right
    info.horizontalPagination = .fit
    info.verticalPagination = .automatic
    info.isHorizontallyCentered = false
    info.jobDisposition = .save
    info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = tmp
    let op = session.web.printOperation(with: info)
    op.showsPrintPanel = false
    op.showsProgressPanel = false
    op.view?.frame = CGRect(origin: .zero, size: paper)
    return try await withCheckedThrowingContinuation { c in
      let delegate = PrintDelegate { ok in
        if ok, let data = try? Data(contentsOf: tmp) {
          c.resume(returning: data)
        } else {
          c.resume(throwing: ExportError.render("Printing to PDF failed"))
        }
      }
      op.runModal(
        for: session.window, delegate: delegate,
        didRun: #selector(PrintDelegate.printOperationDidRun(_:success:contextInfo:)),
        contextInfo: nil)
      objc_setAssociatedObject(op, &PrintDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN)
    }
  }

  static func png(html: String, base: URL?, width: CGFloat) async throws -> Data {
    let session = WebExport(width: width)
    defer { session.window.close() }
    try await session.load(html, base: base)
    let h =
      (try await session.web.evaluateJavaScript("document.documentElement.scrollHeight")
      as? NSNumber)?.doubleValue ?? 1000
    let size = CGSize(width: width, height: min(h, 30000))
    session.window.setContentSize(size)
    session.web.frame = CGRect(origin: .zero, size: size)
    let config = WKSnapshotConfiguration()
    config.rect = CGRect(origin: .zero, size: size)
    let image = try await session.web.takeSnapshot(configuration: config)
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
    else { throw ExportError.render("Snapshot failed") }
    return png
  }
}

private final class PrintDelegate: NSObject {
  nonisolated(unsafe) static var key = 0
  let done: (Bool) -> Void
  init(_ done: @escaping (Bool) -> Void) { self.done = done }
  @objc func printOperationDidRun(
    _ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?
  ) {
    done(success)
  }
}
