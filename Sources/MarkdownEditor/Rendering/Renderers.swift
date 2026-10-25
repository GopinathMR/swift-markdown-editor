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
    default:
      return RenderResult(image: nil, size: .zero, error: "Rendering not available yet")
    }
  }
}
