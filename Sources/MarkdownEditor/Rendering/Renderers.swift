import AppKit

/// Dispatches a render request to the renderer for its kind.
@MainActor
enum Renderers {
  static func render(_ req: RenderRequest, darkMode: Bool) async -> RenderResult {
    switch req {
    case .image(let url):
      return await ImageLoader.load(url)
    default:
      return RenderResult(image: nil, size: .zero, error: "Rendering not available yet")
    }
  }
}
