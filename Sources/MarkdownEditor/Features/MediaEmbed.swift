import AppKit

/// Attributes of a single HTML start tag: `<video src="a.mp4" width=320 controls>`.
enum HTMLTag {
  static func attributes(_ tag: String) -> [String: String] {
    var out: [String: String] = [:]
    for m in tag.matches(
      of: #/([A-Za-z_:][-A-Za-z0-9_:.]*)\s*(?:=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+)))?/#)
    {
      let name = String(m.1).lowercased()
      out[name] = String(m.2 ?? m.3 ?? m.4 ?? "")
    }
    return out
  }

  static func name(_ tag: String) -> String? {
    tag.firstMatch(of: #/^\s*<([A-Za-z][A-Za-z0-9]*)/#).map { String($0.1).lowercased() }
  }
}

/// `<img src alt width style="zoom:50%">`.
struct ImageTag: Equatable {
  var src: String
  var alt: String
  var size: String?

  static func parse(_ html: String) -> ImageTag? {
    let t = html.trimmingCharacters(in: .whitespacesAndNewlines)
    guard HTMLTag.name(t) == "img", !t.dropFirst().contains("<") else { return nil }
    let a = HTMLTag.attributes(String(t.dropFirst(4)))
    guard let src = a["src"], !src.isEmpty else { return nil }
    var size = a["width"]
    if let style = a["style"], let z = style.firstMatch(of: #/zoom\s*:\s*([0-9.]+%?)/#) {
      size = "zoom:" + z.1
    }
    return ImageTag(src: src, alt: a["alt"] ?? "", size: size)
  }

  /// Apply a size spec to an image's natural size, capped to `width`.
  static func apply(_ spec: String?, natural: CGSize, width: CGFloat) -> CGSize {
    guard natural.width > 0, natural.height > 0 else { return natural }
    var w = natural.width
    if let spec {
      if spec.hasPrefix("zoom:") {
        let v = String(spec.dropFirst(5))
        let f = v.hasSuffix("%") ? (Double(v.dropLast()) ?? 100) / 100 : Double(v) ?? 1
        w = natural.width * f
      } else if spec.hasSuffix("%"), let p = Double(spec.dropLast()) {
        w = width * p / 100
      } else if let px = Double(spec.replacingOccurrences(of: "px", with: "")) {
        w = px
      }
    }
    w = min(w, width)
    return CGSize(width: w, height: natural.height * w / natural.width)
  }
}

/// `<video>`, `<audio>` and `<iframe>` blocks, shown as live overlays.
struct MediaEmbed: Equatable {
  enum Kind: Equatable { case video, audio, iframe }
  var kind: Kind
  var source: String
  var width: CGFloat?
  var height: CGFloat?

  static func parse(_ html: String) -> MediaEmbed? {
    let t = html.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let name = HTMLTag.name(t),
      let kind = ["video": Kind.video, "audio": .audio, "iframe": .iframe][name]
    else { return nil }
    let open = t.firstMatch(of: #/^<[^>]*>/#).map { String($0.0) } ?? t
    let a = HTMLTag.attributes(String(open.dropFirst(name.count + 1)))
    var src = a["src"]
    if src == nil, let s = t.firstMatch(of: #/<source[^>]*\ssrc\s*=\s*["']([^"']+)["']/#) {
      src = String(s.1)
    }
    guard let source = src, !source.isEmpty else { return nil }
    func px(_ v: String?) -> CGFloat? {
      v.flatMap { Double($0.replacingOccurrences(of: "px", with: "")) }.map { CGFloat($0) }
    }
    return MediaEmbed(kind: kind, source: source, width: px(a["width"]), height: px(a["height"]))
  }
}

/// Loads images for the render cache: files, http(s) and data URLs.
enum ImageLoader {
  static func load(_ url: URL) async -> RenderResult {
    let data: Data?
    if url.isFileURL {
      data = await Task.detached { try? Data(contentsOf: url) }.value
    } else if url.scheme == "data" {
      data = try? Data(contentsOf: url)
    } else {
      data = try? await URLSession.shared.data(from: url).0
    }
    guard let data, let image = NSImage(data: data) else {
      return RenderResult(
        image: nil, size: CGSize(width: 0, height: 0),
        error: "Image not found: \(url.isFileURL ? url.path : url.absoluteString)")
    }
    // Pixel size at 2x = points; avoids huge 72-dpi screenshots doubling up.
    var size = image.size
    if let rep = image.representations.first, rep.pixelsWide > 0,
      rep.pixelsWide >= Int(size.width) * 2
    {
      size = CGSize(width: CGFloat(rep.pixelsWide) / 2, height: CGFloat(rep.pixelsHigh) / 2)
    }
    return RenderResult(image: image, size: size)
  }
}
