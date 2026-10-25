import MarkdownEditor
import SwiftUI

struct ContentView: View {
  @Bindable var document: DemoDocument
  @Bindable var controller: MarkdownEditorController
  @State private var preferences = DemoPreferences.launchPreferences()
  @State private var theme = DemoPreferences.launchTheme()

  var body: some View {
    MarkdownEditor(
      fileURL: document.url, controller: controller, preferences: preferences, theme: theme,
      outlinePosition: DemoPreferences.launchOutline()
    )
    .safeAreaInset(edge: .bottom, spacing: 0) { StatusBar(controller: controller) }
    .focusedSceneValue(\.markdownEditorController, controller)
    .preferredColorScheme(UserDefaults.standard.bool(forKey: "light") ? .light : nil)
    .navigationTitle(
      (controller.fileURL ?? document.url).lastPathComponent
        + (controller.isDirty ? " — Edited" : "")
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
      if UserDefaults.standard.object(forKey: "watch") != nil {
        controller.watchFile = UserDefaults.standard.bool(forKey: "watch")
      }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {  // after renders settle
          controller.setSelection(NSRange(location: caret, length: 0))
        }
      }
    }
  }
}

/// View ▸ Outline position and Watch File, for the focused editor.
struct DemoViewCommands: Commands {
  @FocusedValue(\.markdownEditorController) private var controller

  var body: some Commands {
    CommandGroup(after: .sidebar) {
      Picker(
        "Outline",
        selection: Binding(
          get: { controller?.outlinePosition ?? .right }, set: { controller?.outlinePosition = $0 })
      ) {
        Text("Outline on Right").tag(OutlinePosition.right)
        Text("Outline on Left").tag(OutlinePosition.left)
        Text("Hide Outline").tag(OutlinePosition.hidden)
      }
      .pickerStyle(.inline)
      Toggle(
        "Watch File for Changes",
        isOn: Binding(get: { controller?.watchFile ?? true }, set: { controller?.watchFile = $0 }))
    }
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
