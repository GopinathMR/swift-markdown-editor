import AppKit

/// VoiceOver rotors over the document structure. Each item moves the caret to its source
/// range and is announced with a label: heading title, link text, image alt, LaTeX source.
@MainActor
final class StructureRotor: NSObject, @preconcurrency NSAccessibilityCustomRotorItemSearchDelegate {
  enum Kind: String, CaseIterable {
    case headings = "Headings"
    case links = "Links"
    case tables = "Tables"
    case images = "Images"
    case math = "Equations"
    case tasks = "Tasks"
  }

  weak var coordinator: EditorCoordinator?
  let kind: Kind

  init(_ kind: Kind, coordinator: EditorCoordinator) {
    self.kind = kind
    self.coordinator = coordinator
  }

  /// (range, label) for every item of this kind, in document order.
  func items() -> [(NSRange, String)] {
    guard let c = coordinator else { return [] }
    let text = c.text
    var out: [(NSRange, String)] = []
    switch kind {
    case .headings:
      out = c.model.headings.map { ($0.range, "Heading level \($0.level), \($0.title)") }
    case .tables:
      out = c.model.blocks(where: { $0 == .table }).map { b, off in
        let t = TableModel(source: text.substring(with: b.range.shifted(by: off)))
        return (
          b.range.shifted(by: off),
          "Table, \(t?.columnCount ?? 0) columns, \(t?.rows.count ?? 0) rows"
        )
      }
    case .math:
      out = c.model.blocks(where: { $0 == .math }).map { b, off in
        (
          b.range.shifted(by: off),
          "Equation: "
            + (b.content.map { text.substring(with: $0.shifted(by: off)) } ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        )
      }
    case .tasks:
      for (b, off) in c.model.blocks(where: {
        if case .listItem(_, let t) = $0 { return t != nil } else { return false }
      }) {
        if case .listItem(_, let checked) = b.kind {
          out.append(
            (
              b.range.shifted(by: off),
              (checked == true ? "Checked: " : "Unchecked: ")
                + c.parser.visibleText(of: b.children.first ?? b, offset: off, text: text)
            ))
        }
      }
    case .links, .images:
      for e in c.model.entries {
        forEachInline(e.block) { i in
          let r = i.range.shifted(by: e.start)
          switch (kind, i.kind) {
          case (.links, .link), (.links, .autolink):
            out.append(
              (
                r,
                "Link, "
                  + text.substring(with: r).trimmingCharacters(
                    in: CharacterSet(charactersIn: "[]<>"))
              ))
          case (.images, .image(_, let alt)):
            out.append((r, "Image, " + (alt.isEmpty ? "no description" : alt)))
          default: break
          }
        }
      }
    }
    return out.sorted { $0.0.location < $1.0.location }
  }

  func rotor(
    _ rotor: NSAccessibilityCustomRotor,
    resultFor search: NSAccessibilityCustomRotor.SearchParameters
  )
    -> NSAccessibilityCustomRotor.ItemResult?
  {
    guard let c = coordinator else { return nil }
    let all = items()
    let current = search.currentItem?.targetRange.location ?? c.textView.selectedRange().location
    let hit: (NSRange, String)?
    switch search.searchDirection {
    case .next:
      // From the caret (no current item) an item at the caret counts; from an item, move on.
      let from = search.currentItem == nil ? current - 1 : current
      hit = all.first { $0.0.location > from }
    case .previous: hit = all.last { $0.0.location < current }
    @unknown default: hit = nil
    }
    guard let (range, label) = hit else { return nil }
    let result = NSAccessibilityCustomRotor.ItemResult(targetElement: c.textView)
    result.targetRange = NSRange(location: range.location, length: 0)
    result.customLabel = label
    return result
  }
}

extension EditorCoordinator {
  func makeRotors() -> [NSAccessibilityCustomRotor] {
    StructureRotor.Kind.allCases.map { kind in
      let delegate = StructureRotor(kind, coordinator: self)
      rotorDelegates.append(delegate)
      return NSAccessibilityCustomRotor(label: kind.rawValue, itemSearchDelegate: delegate)
    }
  }
}
