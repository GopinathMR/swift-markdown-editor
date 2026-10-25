import AppKit

/// Dispatches a render request to the renderer for its kind.
@MainActor
enum Renderers {
  static func render(_ req: RenderRequest, darkMode: Bool) async -> RenderResult {
    switch req {
    case .image(let url):
      return await ImageLoader.load(url)
    case .math(let latex, let display, let dark, let fontSize, let number):
      return MathRenderer.render(
        latex: latex, display: display, dark: dark, fontSize: fontSize, number: number)
    case .diagram(let kind, let source, let dark):
      return await DiagramRenderer.shared.render(kind, source: source, dark: dark)
    case .html(let html, let width, let dark):
      return HTMLBlockRenderer.render(html, width: width, dark: dark)
    }
  }
}
