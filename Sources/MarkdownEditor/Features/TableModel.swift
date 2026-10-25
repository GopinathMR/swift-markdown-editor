import AppKit

struct TableModel: Equatable {
  var header: [String]
  var rows: [[String]]
  init?(source: String) { return nil }
}

enum TableLayout {
  @MainActor static func size(_ t: TableModel, theme: ResolvedTheme, width: CGFloat) -> CGSize {
    .zero
  }
}
