import SwiftUI

/// The document outline: nested headings, current section highlighted, click to jump.
public struct MarkdownOutline: View {
  let controller: MarkdownEditorController

  public init(controller: MarkdownEditorController) {
    self.controller = controller
  }

  public var body: some View {
    List {
      OutlineGroup(controller.outline, children: \.childrenOrNil) { item in
        Button {
          controller.reveal(item.id)
        } label: {
          HStack(spacing: 4) {
            if let n = item.number, controller.showsHeadingNumbers {
              Text(n).foregroundStyle(.secondary)
            }
            Text(item.title.isEmpty ? "Untitled" : item.title).lineLimit(1)
          }
          .fontWeight(item.id == controller.currentHeading ? .semibold : .regular)
          .foregroundStyle(item.id == controller.currentHeading ? Color.accentColor : Color.primary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Heading level \(item.level): \(item.title)")
      }
    }
    .listStyle(.sidebar)
  }
}

extension OutlineItem {
  public var childrenOrNil: [OutlineItem]? { children.isEmpty ? nil : children }
}
