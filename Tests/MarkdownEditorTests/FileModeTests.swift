import AppKit
import Testing

@testable import MarkdownEditor

/// File-mode harness: a temp file opened by the editor, with a controller attached.
@MainActor
final class FileHarness {
  let h = Harness("")
  let ctl = MarkdownEditorController()
  let url: URL
  var errors: [EditorError] = []

  init(_ text: String, watch: Bool = true) throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    url = dir.appendingPathComponent("doc.md")
    try text.write(to: url, atomically: true, encoding: .utf8)
    h.c.controller = ctl
    ctl.coordinator = h.c
    h.c.hooks.onError = { [weak self] in self?.errors.append($0) }
    h.c.open(url, watch: watch)
  }

  var buffer: String { h.c.storage.string }

  /// Another app writes, without file coordination (like vim, git, `echo >`).
  func external(_ shell: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", shell]
    p.currentDirectoryURL = url.deletingLastPathComponent()
    try? p.run()
    p.waitUntilExit()
  }

  /// Presenter callbacks arrive on the main queue: suspend (don't spin) until `done`.
  func settle(_ done: @autoclosure () -> Bool = false) async {
    for _ in 0..<50 {
      if done() { return }
      try? await Task.sleep(for: .milliseconds(100))
    }
  }
}

@MainActor @Test func opensSavesAndTracksDirty() async throws {
  let f = try FileHarness("# Hi\n")
  #expect(f.buffer == "# Hi\n" && !f.ctl.isDirty && f.ctl.fileURL == f.url)
  f.h.caret(4)
  f.h.type("!")
  #expect(f.ctl.isDirty)
  f.h.tv.undoManager?.undo()
  await f.settle(!f.ctl.isDirty)  // undo flushes on the next main-queue turn
  #expect(f.buffer == "# Hi\n", "after undo: \(f.buffer.debugDescription)")
  #expect(!f.ctl.isDirty)  // undo back to the saved text is clean
  f.h.type("?")
  try f.ctl.save()
  #expect(!f.ctl.isDirty)
  #expect(try String(contentsOf: f.url, encoding: .utf8) == f.buffer)
}

@MainActor @Test func unreadableFileIsReported() throws {
  let f = try FileHarness("")
  try Data([0xFF, 0xFE, 0xFF]).write(to: f.url)
  f.h.c.open(f.url, watch: false)
  #expect(f.errors.contains(.fileUnreadable(f.url)))
}

@MainActor @Test func cleanBufferFollowsExternalChanges() async throws {
  let f = try FileHarness("one\n")
  f.h.caret(2)
  f.external("printf 'one\\ntwo\\n' > doc.md")
  await f.settle(f.buffer == "one\ntwo\n")
  #expect(f.buffer == "one\ntwo\n")
  #expect(f.h.tv.selectedRange().location == 2)
  #expect(!f.ctl.isDirty)
  // An atomic replace (write elsewhere, rename over) is followed too.
  f.external("printf 'three\\n' > tmp.md && mv tmp.md doc.md")
  await f.settle(f.buffer == "three\n")
  #expect(f.buffer == "three\n")
}

@MainActor @Test func watchingCanBeTurnedOffAndCatchesUpWhenOn() async throws {
  let f = try FileHarness("a\n")
  f.ctl.watchFile = false
  f.external("printf 'b\\n' > doc.md")
  await f.settle()
  #expect(f.buffer == "a\n")
  f.ctl.watchFile = true
  #expect(f.buffer == "b\n")
}

@MainActor @Test func ownSavesDoNotEcho() async throws {
  let f = try FileHarness("x\n")
  var asked = 0
  f.h.c.hooks.resolveExternalChange = { _ in
    asked += 1
    return .keepMine
  }
  f.h.caret(1)
  f.h.type("y")
  try f.ctl.save()
  await f.settle()
  #expect(asked == 0)
  #expect(f.buffer == "xy\n" && !f.ctl.isDirty)
}

@MainActor @Test func dirtyBufferAsksAndHonoursTheChoice() async throws {
  let f = try FileHarness("base\n")
  var changes: [ExternalChange] = []
  var choice = ExternalChangeChoice.keepMine
  f.h.c.hooks.resolveExternalChange = { c in
    changes.append(c)
    return choice
  }
  f.h.caret(4)
  f.h.type("!")
  f.external("printf 'theirs\\n' > doc.md")
  await f.settle(!changes.isEmpty)
  #expect(changes.map(\.diskText) == ["theirs\n"])
  #expect(f.buffer == "base!\n" && f.ctl.isDirty)  // kept mine
  choice = .reload
  f.external("printf 'theirs 2\\n' > doc.md")
  await f.settle(f.buffer == "theirs 2\n")
  #expect(f.buffer == "theirs 2\n" && !f.ctl.isDirty)
  #expect(f.h.tv.undoManager?.canUndo == false)
}

@MainActor @Test func identicalExternalWriteIsNotAConflict() async throws {
  let f = try FileHarness("v1\n")
  var asked = 0
  f.h.c.hooks.resolveExternalChange = { _ in
    asked += 1
    return .reload
  }
  f.h.caret(2)
  f.h.type("x")  // buffer "v1x\n"
  f.external("printf 'v1x\\n' > doc.md")
  await f.settle(!f.ctl.isDirty)
  #expect(asked == 0 && !f.ctl.isDirty)
}

@MainActor @Test func movesAreFollowedAndDeletesReported() async throws {
  let f = try FileHarness("m\n")
  f.external("mv doc.md moved.md")
  await f.settle(f.ctl.fileURL?.lastPathComponent == "moved.md")
  let moved = f.url.deletingLastPathComponent().appendingPathComponent("moved.md")
  #expect(f.ctl.fileURL?.standardizedFileURL.path == moved.standardizedFileURL.path)
  f.external("rm moved.md")
  // A plain `rm` is only noticed when the app is next activated.
  NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
  #expect(f.ctl.isDirty)
  #expect(f.errors.contains { if case .fileDeleted = $0 { return true } else { return false } })
  try f.ctl.save()  // recreates it
  #expect(FileManager.default.fileExists(atPath: moved.path))
}

@MainActor @Test func outlinePaneMovesAndHides() {
  let h = Harness("# A\n")
  let ctl = MarkdownEditorController()
  h.c.controller = ctl
  ctl.coordinator = h.c
  let split = h.c.container.subviews.first as! NSSplitView
  h.c.setOutline(.right)
  #expect(split.arrangedSubviews.count == 2 && split.arrangedSubviews.last === h.c.outlineHost)
  ctl.outlinePosition = .left
  #expect(split.arrangedSubviews.first === h.c.outlineHost)
  ctl.outlinePosition = .hidden
  #expect(split.arrangedSubviews.count == 1)
  #expect(h.tv.textLayoutManager != nil)
}
