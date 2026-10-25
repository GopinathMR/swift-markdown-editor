import MarkdownEditor
import SwiftUI

struct ContentView: View {
  @Bindable var document: DemoDocument
  @State private var controller = MarkdownEditorController()
  @State private var preferences = DemoPreferences.launchPreferences()
  @State private var theme = DemoPreferences.launchTheme()
  @State private var showOutline =
    UserDefaults.standard.object(forKey: "outline") == nil
    || UserDefaults.standard.bool(forKey: "outline")

  var body: some View {
    NavigationSplitView(columnVisibility: .constant(showOutline ? .all : .detailOnly)) {
      OutlineSidebar(controller: controller)
        .navigationSplitViewColumnWidth(min: 180, ideal: 230)
    } detail: {
      MarkdownEditor(
        text: $document.text, documentURL: document.url, controller: controller,
        preferences: preferences, theme: theme
      )
      .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar(controller: controller) }
    }
    .focusedSceneValue(\.markdownEditorController, controller)
    .preferredColorScheme(UserDefaults.standard.bool(forKey: "light") ? .light : nil)
    .navigationTitle(
      (document.url?.lastPathComponent ?? "Untitled") + (document.isDirty ? " — Edited" : "")
    )
    .toolbar {
      ToolbarItemGroup {
        Toggle(
          isOn: Binding(
            get: { controller.mode == .source }, set: { controller.mode = $0 ? .source : .rendered }
          )
        ) {
          Label("Source", systemImage: "chevron.left.forwardslash.chevron.right")
        }
        .accessibilityIdentifier("source-toggle")
        Toggle(isOn: $controller.isFocusMode) { Label("Focus", systemImage: "scope") }
        Toggle(isOn: $controller.isTypewriterMode) {
          Label("Typewriter", systemImage: "text.aligncenter")
        }
        Button {
          controller.showFind(replace: true)
        } label: {
          Label("Find", systemImage: "magnifyingglass")
        }
      }
    }
    .onAppear {
      if UserDefaults.standard.bool(forKey: "source") { controller.mode = .source }
      if UserDefaults.standard.bool(forKey: "focus") { controller.isFocusMode = true }
      if let slug = UserDefaults.standard.string(forKey: "heading") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { controller.reveal(slug) }
      }
      if let q = UserDefaults.standard.string(forKey: "find") {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
          controller.showFind(replace: true, query: q)
        }
      }
      if UserDefaults.standard.object(forKey: "caret") != nil {
        let caret = UserDefaults.standard.integer(forKey: "caret")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
          controller.setSelection(NSRange(location: caret, length: 0))
        }
      }
    }
  }
}

struct OutlineSidebar: View {
  let controller: MarkdownEditorController

  var body: some View {
    MarkdownOutline(controller: controller)
  }
}

struct StatusBar: View {
  let controller: MarkdownEditorController

  var body: some View {
    HStack(spacing: 14) {
      Spacer()
      let s = controller.stats
      if s.selectionCharacters > 0 {
        Text("\(s.selectionWords) of \(s.words) words selected")
      } else {
        Text("\(s.words) words")
      }
      Text("\(s.characters) characters")
      Text("\(s.lines) lines")
      Text("\(max(1, Int(s.readingMinutes.rounded()))) min read")
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12)
    .padding(.vertical, 5)
    .background(.bar)
  }
}
