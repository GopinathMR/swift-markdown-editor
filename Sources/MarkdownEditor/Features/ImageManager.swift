import AVKit
import AppKit
import UniformTypeIdentifiers
import WebKit

/// Typora's image rules: where inserted images go and how their paths are written.
struct ImageRules {
  enum Target: Equatable {
    case keep
    case copy(URL)
    case upload
  }

  var preferences: EditorPreferences
  var documentURL: URL?
  /// `typora-copy-images-to` from front matter; overrides the preference.
  var frontMatterTarget: String?

  var documentFolder: URL? { documentURL?.deletingLastPathComponent() }

  var target: Target {
    if let fm = frontMatterTarget?.trimmingCharacters(in: .whitespaces), !fm.isEmpty {
      return fm == "upload" ? .upload : folder(fm).map(Target.copy) ?? .keep
    }
    switch preferences.imageInsert {
    case .none: return .keep
    case .upload: return .upload
    case .copy(let path): return folder(path).map(Target.copy) ?? .keep
    }
  }

  /// Resolve a folder spec (`./assets`, `${filename}.assets`, `~/Pictures`) against the document.
  func folder(_ spec: String) -> URL? {
    let name = documentURL?.deletingPathExtension().lastPathComponent ?? "untitled"
    let s = (spec.replacingOccurrences(of: "${filename}", with: name) as NSString)
      .expandingTildeInPath
    if s.hasPrefix("/") { return URL(fileURLWithPath: s) }
    guard let dir = documentFolder else { return nil }
    return URL(fileURLWithPath: s, relativeTo: dir).standardizedFileURL
  }

  /// How `file` is written into the markdown.
  func markdownPath(_ file: URL) -> String {
    guard file.isFileURL else { return file.absoluteString }
    var path = file.standardizedFileURL.path
    if preferences.preferRelativePaths, let dir = documentFolder {
      path = Self.relativePath(from: dir.standardizedFileURL, to: file.standardizedFileURL)
      if preferences.ensureDotSlash, !path.hasPrefix("../") { path = "./" + path }
    }
    if preferences.escapeImageURL {
      path =
        path.addingPercentEncoding(
          withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "()")))
        ?? path
    } else if path.contains(" ") {
      path = "<" + path + ">"
    }
    return path
  }

  static func relativePath(from dir: URL, to file: URL) -> String {
    let a = dir.pathComponents
    let b = file.pathComponents
    var i = 0
    while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
    return (Array(repeating: "..", count: a.count - i) + b[i...]).joined(separator: "/")
  }

  static func uniqueURL(in folder: URL, name: String) -> URL {
    var url = folder.appendingPathComponent(name)
    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var n = 1
    while FileManager.default.fileExists(atPath: url.path) {
      url = folder.appendingPathComponent("\(base)-\(n)" + (ext.isEmpty ? "" : ".\(ext)"))
      n += 1
    }
    return url
  }

  static let imageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tiff", "tif", "heic", "avif",
  ]
  static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "webm"]
  static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aac", "ogg", "flac"]
}

extension EditorCoordinator {
  var imageRules: ImageRules {
    ImageRules(
      preferences: preferences, documentURL: documentURL,
      frontMatterTarget: styler.frontMatterValue("typora-copy-images-to"))
  }

  // MARK: Insert

  func insertImageCommand() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = [.image]
    guard panel.runModal() == .OK else { return }
    insertFiles(panel.urls, at: textView.selectedRange())
  }

  /// Images become `![]()`, video/audio become tags, following the insert rules.
  func insertFiles(_ urls: [URL], at range: NSRange) {
    let rules = imageRules
    Task { @MainActor in
      var parts: [String] = []
      var toUpload: [(Int, URL)] = []
      for url in urls {
        let ext = url.pathExtension.lowercased()
        var file = url
        if case .copy(let folder) = rules.target {
          do { file = try self.copyIfNeeded(url, into: folder) } catch {
            self.hooks.onError(.imageOperation(error.localizedDescription))
          }
        }
        let path = rules.markdownPath(file)
        if ImageRules.videoExtensions.contains(ext) {
          parts.append("<video src=\"\(path)\" controls></video>")
        } else if ImageRules.audioExtensions.contains(ext) {
          parts.append("<audio src=\"\(path)\" controls></audio>")
        } else {
          if rules.target == .upload, ImageRules.imageExtensions.contains(ext) {
            toUpload.append((parts.count, url))
          }
          parts.append("![\(url.deletingPathExtension().lastPathComponent)](\(path))")
        }
      }
      if !toUpload.isEmpty {
        guard let upload = self.hooks.uploadImages else {
          self.hooks.onError(.imageRefused("No image uploader is configured"))
          return
        }
        do {
          let remote = try await upload(toUpload.map(\.1))
          for (i, r) in zip(toUpload.map(\.0), remote) {
            parts[i] =
              "![\(toUpload.first { $0.0 == i }!.1.deletingPathExtension().lastPathComponent)](\(r.absoluteString))"
          }
        } catch {
          self.hooks.onError(.imageOperation(error.localizedDescription))
          return
        }
      }
      let s = parts.joined(separator: self.eol)
      self.replace(
        range, with: s,
        selectAfter: NSRange(location: range.location + (s as NSString).length, length: 0))
    }
  }

  private func copyIfNeeded(_ url: URL, into folder: URL) throws -> URL {
    if url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {
      return url
    }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let dest = ImageRules.uniqueURL(in: folder, name: url.lastPathComponent)
    if url.isFileURL {
      try FileManager.default.copyItem(at: url, to: dest)
    } else {
      try Data(contentsOf: url).write(to: dest)
    }
    return dest
  }

  /// Pasted image data: copy rule → file in that folder; else ask the host; else refuse.
  func pasteImageData(_ data: Data, ext: String) {
    let rules = imageRules
    let range = textView.selectedRange()
    Task { @MainActor in
      var url: URL?
      if case .copy(let folder) = rules.target {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        do {
          try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
          let dest = ImageRules.uniqueURL(
            in: folder, name: "image-\(f.string(from: Date())).\(ext)")
          try data.write(to: dest)
          url = dest
        } catch {
          self.hooks.onError(.imageOperation(error.localizedDescription))
          return
        }
      } else {
        url = await self.hooks.imageStore(PastedImage(data: data, fileExtension: ext))
      }
      guard var file = url else {
        self.hooks.onError(
          .imageRefused(
            "Set an image folder (preferences or typora-copy-images-to) to paste images"))
        return
      }
      if rules.target == .upload, let upload = self.hooks.uploadImages,
        let remote = try? await upload([file]).first
      {
        file = remote
      }
      let s = "![](\(rules.markdownPath(file)))"
      self.replace(
        range, with: s,
        selectAfter: NSRange(location: range.location + (s as NSString).length, length: 0))
    }
  }

  /// Image data or image files on the pasteboard. Returns false when there are none.
  func pasteImagesIfPresent(_ pb: NSPasteboard) -> Bool {
    if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
      as? [URL],
      !urls.isEmpty,
      urls.allSatisfy({ ImageRules.imageExtensions.contains($0.pathExtension.lowercased()) })
    {
      insertFiles(urls, at: textView.selectedRange())
      return true
    }
    if let png = pb.data(forType: .png) {
      pasteImageData(png, ext: "png")
      return true
    }
    if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
    {
      pasteImageData(png, ext: "png")
      return true
    }
    return false
  }

  func handleDrop(_ info: NSDraggingInfo) -> Bool {
    guard mode == .rendered,
      let urls = info.draggingPasteboard.readObjects(
        forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
      !urls.isEmpty
    else { return false }
    let media = ImageRules.imageExtensions.union(ImageRules.videoExtensions).union(
      ImageRules.audioExtensions)
    guard urls.allSatisfy({ media.contains($0.pathExtension.lowercased()) }) else { return false }
    let at = textView.characterIndexForInsertion(
      at: textView.convert(info.draggingLocation, from: nil))
    insertFiles(urls, at: NSRange(location: at, length: 0))
    return true
  }

  // MARK: Context menu

  /// The image (markdown or `<img>`) at `index`, with its absolute range.
  func image(at index: Int) -> (
    src: String, alt: String, size: String?, range: NSRange, html: Bool
  )? {
    for loc in [index, index - 1] where loc >= 0 {
      if let (i, off) = model.inline(at: loc), case .image(let src, let alt) = i.kind {
        let r = i.range.shifted(by: off)
        return (src, alt, i.size, r, text.substring(with: r).hasPrefix("<"))
      }
      if let (b, off) = model.innermostBlock(at: loc), b.kind == .html,
        let tag = ImageTag.parse(text.substring(with: b.range.shifted(by: off)))
      {
        var r = b.range.shifted(by: off)
        while r.length > 0, [0x0A, 0x0D].contains(text.character(at: r.end - 1)) { r.length -= 1 }
        return (tag.src, tag.alt, tag.size, r, true)
      }
    }
    return nil
  }

  func decorateImageMenu(_ menu: NSMenu, index: Int) {
    guard let img = image(at: index) else { return }
    let url = styler.resolveURL(img.src)
    var items: [NSMenuItem] = []
    func item(_ title: String, _ action: Selector, _ obj: Any? = nil) {
      let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
      i.target = self
      i.representedObject = obj ?? img.range.location
      items.append(i)
    }
    if url?.isFileURL == true {
      item("Reveal in Finder", #selector(menuRevealImage(_:)))
      item("Move Image to…", #selector(menuMoveImage(_:)))
      item("Copy Image to…", #selector(menuCopyImage(_:)))
      if hooks.uploadImages != nil { item("Upload Image", #selector(menuUploadImage(_:))) }
      item("Delete Image File", #selector(menuDeleteImage(_:)))
    } else if url != nil {
      item("Download Image to…", #selector(menuCopyImage(_:)))
    }
    let zoom = NSMenuItem(title: "Zoom Image", action: nil, keyEquivalent: "")
    let sub = NSMenu()
    for z in [25, 33, 50, 67, 80, 100, 150, 200] {
      let i = NSMenuItem(title: "\(z)%", action: #selector(menuZoomImage(_:)), keyEquivalent: "")
      i.target = self
      i.representedObject = [img.range.location, z]
      sub.addItem(i)
    }
    zoom.submenu = sub
    items.append(zoom)
    items.append(.separator())
    for (n, i) in items.enumerated() { menu.insertItem(i, at: n) }
  }

  private func imageFromMenu(_ sender: NSMenuItem) -> (
    src: String, alt: String, size: String?, range: NSRange, html: Bool
  )? {
    let loc =
      (sender.representedObject as? Int) ?? ((sender.representedObject as? [Int])?.first ?? -1)
    return image(at: loc + 1)
  }

  /// Rewrite an image reference with a new source and/or size.
  func rewriteImage(
    _ img: (src: String, alt: String, size: String?, range: NSRange, html: Bool),
    src: String? = nil, size: String?? = nil
  ) {
    let s = src ?? img.src
    let z = size ?? img.size
    let new: String
    if let z, z != "zoom:100%" {
      let style = z.hasPrefix("zoom:") ? " style=\"zoom:\(z.dropFirst(5))\"" : " width=\"\(z)\""
      new = "<img src=\"\(s)\" alt=\"\(img.alt)\"\(style) />"
    } else {
      new = "![\(img.alt)](\(s))"
    }
    replace(img.range, with: new)
  }

  @objc func menuRevealImage(_ sender: NSMenuItem) {
    guard let img = imageFromMenu(sender), let url = styler.resolveURL(img.src) else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  @objc func menuMoveImage(_ sender: NSMenuItem) { relocateImage(sender, move: true) }
  @objc func menuCopyImage(_ sender: NSMenuItem) { relocateImage(sender, move: false) }

  private func relocateImage(_ sender: NSMenuItem, move: Bool) {
    guard let img = imageFromMenu(sender), let url = styler.resolveURL(img.src) else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.prompt = move ? "Move" : "Copy"
    guard panel.runModal() == .OK, let folder = panel.url else { return }
    do {
      let dest = ImageRules.uniqueURL(in: folder, name: url.lastPathComponent)
      if move {
        try FileManager.default.moveItem(at: url, to: dest)
      } else if url.isFileURL {
        try FileManager.default.copyItem(at: url, to: dest)
      } else {
        try Data(contentsOf: url).write(to: dest)
      }
      rewriteImage(img, src: imageRules.markdownPath(dest))
    } catch {
      hooks.onError(.imageOperation(error.localizedDescription))
    }
  }

  @objc func menuDeleteImage(_ sender: NSMenuItem) {
    guard let img = imageFromMenu(sender), let url = styler.resolveURL(img.src) else { return }
    // To the Trash, not unlinked: the user can get it back.
    NSWorkspace.shared.recycle([url]) { _, error in
      if let error {
        MainActor.assumeIsolated { self.hooks.onError(.imageOperation(error.localizedDescription)) }
      }
    }
    replace(img.range, with: "")
  }

  @objc func menuUploadImage(_ sender: NSMenuItem) {
    guard let img = imageFromMenu(sender), let url = styler.resolveURL(img.src),
      let upload = hooks.uploadImages
    else { return }
    Task { @MainActor in
      do {
        if let remote = try await upload([url]).first,
          ["http", "https"].contains(remote.scheme ?? "")
        {
          self.rewriteImage(img, src: remote.absoluteString)
        }
      } catch {
        self.hooks.onError(.imageOperation(error.localizedDescription))
      }
    }
  }

  @objc func menuZoomImage(_ sender: NSMenuItem) {
    guard let v = sender.representedObject as? [Int], v.count == 2, let img = image(at: v[0] + 1)
    else { return }
    rewriteImage(img, size: .some(v[1] == 100 ? nil : "zoom:\(v[1])%"))
  }

  // MARK: All images

  /// Every image reference in the document, last first (so replacements don't shift).
  func allImages() -> [(src: String, alt: String, size: String?, range: NSRange, html: Bool)] {
    var out: [(String, String, String?, NSRange, Bool)] = []
    for e in model.entries {
      forEachInline(e.block) { i in
        if case .image(let src, let alt) = i.kind {
          let r = i.range.shifted(by: e.start)
          out.append((src, alt, i.size, r, text.substring(with: r).hasPrefix("<")))
        }
      }
    }
    return out.sorted { $0.3.location > $1.3.location }
  }

  /// Copy (or download) every image into `folder` and point references at the copies.
  func copyAllImages(to folder: URL) async {
    let rules = imageRules
    textView.undoManager?.beginUndoGrouping()
    defer { textView.undoManager?.endUndoGrouping() }
    for img in allImages() {
      guard let url = styler.resolveURL(img.src) else { continue }
      do {
        let dest = try copyIfNeeded(url, into: folder)
        rewriteImage(img, src: rules.markdownPath(dest))
      } catch {
        hooks.onError(.imageOperation(error.localizedDescription))
      }
    }
  }

  func uploadAllLocalImages() async {
    guard let upload = hooks.uploadImages else {
      hooks.onError(.imageRefused("No image uploader is configured"))
      return
    }
    let locals = allImages().filter { styler.resolveURL($0.src)?.isFileURL == true }
    guard !locals.isEmpty else { return }
    do {
      let remote = try await upload(locals.compactMap { styler.resolveURL($0.src) })
      textView.undoManager?.beginUndoGrouping()
      for (img, r) in zip(locals, remote) where ["http", "https"].contains(r.scheme ?? "") {
        rewriteImage(img, src: r.absoluteString)
      }
      textView.undoManager?.endUndoGrouping()
    } catch {
      hooks.onError(.imageOperation(error.localizedDescription))
    }
  }
}

// MARK: Media overlays

@MainActor
final class MediaOverlay {
  let embed: MediaEmbed
  let view: NSView
  init(embed: MediaEmbed, view: NSView) {
    self.embed = embed
    self.view = view
  }
}

extension EditorCoordinator {
  func layoutMediaOverlays() {
    var found: [(MediaEmbed, NSRange)] = []
    if mode == .rendered {
      let near = nearViewport()
      for (b, off) in model.blocks(where: { $0 == .html })
      where NSIntersectionRange(b.range.shifted(by: off), near).length > 0 {
        var r = b.range.shifted(by: off)
        while r.length > 0, [0x0A, 0x0D].contains(text.character(at: r.end - 1)) { r.length -= 1 }
        if let m = MediaEmbed.parse(text.substring(with: r)) { found.append((m, r)) }
      }
    }
    while overlays.media.count > found.count {
      overlays.media.removeLast().view.removeFromSuperview()
    }
    for (i, (embed, range)) in found.enumerated() {
      if i < overlays.media.count, overlays.media[i].embed != embed {
        overlays.media[i].view.removeFromSuperview()
        overlays.media[i] = MediaOverlay(embed: embed, view: makeMediaView(embed))
        textView.addSubview(overlays.media[i].view)
      } else if i >= overlays.media.count {
        let o = MediaOverlay(embed: embed, view: makeMediaView(embed))
        overlays.media.append(o)
        textView.addSubview(o.view)
      }
      let view = overlays.media[i].view
      let lastLine = text.lineRange(
        for: NSRange(location: max(range.location, range.end - 1), length: 0)
      ).location
      guard let lm = textView.textLayoutManager, let cs = lm.textContentManager,
        let loc = cs.location(cs.documentRange.location, offsetBy: lastLine)
      else { continue }
      // Exact positions need everything above laid out, not estimated.
      lm.ensureLayout(
        for: NSTextRange(location: cs.documentRange.location, end: loc) ?? cs.documentRange)
      guard let f = lm.textLayoutFragment(for: loc) else { continue }
      let size = Styler.mediaSize(embed, width: (textView.textContainer?.size.width ?? 600) - 20)
      let bottom = f.textLineFragments.last?.typographicBounds.maxY ?? 0
      let y =
        f.layoutFragmentFrame.minY + bottom
        + max(4, (f.layoutFragmentFrame.height - bottom - size.height) / 2)
      let avail = (textView.textContainer?.size.width ?? 600) - 10
      let x = textView.textContainerOrigin.x + 5 + max(0, (avail - size.width) / 2)
      view.frame = CGRect(
        x: x, y: textView.textContainerOrigin.y + y, width: size.width, height: size.height)
    }
  }

  private func makeMediaView(_ embed: MediaEmbed) -> NSView {
    let url = styler.resolveURL(embed.source)
    switch embed.kind {
    case .video, .audio:
      let v = AVPlayerView()
      v.controlsStyle = embed.kind == .audio ? .inline : .floating
      if let url { v.player = AVPlayer(url: url) }
      v.setAccessibilityLabel(embed.kind == .audio ? "Audio" : "Video")
      return v
    case .iframe:
      // Sandboxed: no persistent storage, and never local files.
      let config = WKWebViewConfiguration()
      config.websiteDataStore = .nonPersistent()
      let web = WKWebView(frame: .zero, configuration: config)
      if let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
        web.load(URLRequest(url: url))
      }
      web.setAccessibilityLabel("Embedded web content")
      return web
    }
  }
}
