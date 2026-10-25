import AppKit

enum DemoSample {
  static let text = #"""
    ---
    title: Feature tour
    author: swift-markdown-editor
    ---

    # Feature tour

    [toc]

    ## Writing

    Markdown renders **as you type**. Move the caret into *any* element and its source reappears: try `inline code`, ~~strikethrough~~, ==highlight==, H~2~O, x^2^, <u>underline</u>, <kbd>⌘</kbd> + <kbd>B</kbd>, <span style="color:#d14">coloured text</span>, &copy; entities and emoji :tada: :rocket:.

    Links: [inline](https://example.com), [reference][docs], <https://autolink.dev> and bare www.typora.io. A footnote[^1] too.

    [docs]: https://github.com

    > A blockquote stays quiet,
    > > and nests.

    > [!TIP]
    > Callouts use GitHub's alert syntax.

    ## Images

    ![Hero banner](assets/hero.png)

    Inline images sit in the text <img src="assets/hero.png" alt="small" style="zoom:8%" /> too.

    ## Lists

    - [x] Inline rendering
    - [ ] Click a box to toggle it
    - Bullets
      - nest
        - deeper
    1. Ordered
    2. Lists
       1. renumber for display

    ## Code

    ```swift
    struct Greeter {
      let name: String
      func greet() -> String { "Hello, \(name)!" }
    }
    ```

    ## Math

    Inline math like $e^{i\pi} + 1 = 0$ sits in the text.

    $$
    \int_0^\infty e^{-x^2}\,dx = \frac{\sqrt{\pi}}{2}
    $$

    ## Tables

    | Feature | Status | Notes |
    |:--------|:------:|------:|
    | Tables  | ✅ | Tab between cells |
    | Math    | ✅ | Native typesetting |

    ## Diagrams

    ```mermaid
    graph LR
      A[Write] --> B{Render}
      B --> C[Read]
      B --> D[Edit]
    ```

    ---

    [^1]: Footnotes render at the bottom, with a hover preview.
    """#
}

extension DemoSample {
  /// Write the tour and a generated image into Caches so relative image paths resolve.
  @MainActor static func install() -> URL? {
    let fm = FileManager.default
    guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
    let dir = caches.appendingPathComponent("MarkdownEditorDemo")
    let assets = dir.appendingPathComponent("assets")
    try? fm.createDirectory(at: assets, withIntermediateDirectories: true)
    let hero = assets.appendingPathComponent("hero.png")
    if !fm.fileExists(atPath: hero.path) {
      let image = NSImage(size: NSSize(width: 1200, height: 360), flipped: false) { r in
        NSGradient(colors: [.systemIndigo, .systemPink, .systemOrange])?.draw(in: r, angle: 20)
        let title = NSAttributedString(
          string: "swift-markdown-editor",
          attributes: [
            .font: NSFont.systemFont(ofSize: 84, weight: .heavy), .foregroundColor: NSColor.white,
          ])
        let s = title.size()
        title.draw(at: NSPoint(x: (r.width - s.width) / 2, y: (r.height - s.height) / 2))
        return true
      }
      if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
      {
        try? png.write(to: hero)
      }
    }
    let doc = dir.appendingPathComponent("Feature tour.md")
    try? text.write(to: doc, atomically: true, encoding: .utf8)
    return doc
  }
}
