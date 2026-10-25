import AppKit
import SwiftUI

extension EditorCoordinator {
  /// File mode: read `url`, show it, and watch it when asked.
  func open(_ url: URL, watch: Bool) {
    let f = DocumentFile(url: url)
    file = f
    documentURL = url
    activeController.fileURL = url
    do {
      let text = try f.read()
      f.diskText = text
      load(text)
    } catch {
      f.diskText = ""
      load("")
      hooks.onError(.fileUnreadable(url))
    }
    f.onChange = { [weak self] in self?.externalChange() }
    f.onMove = { [weak self] newURL in
      guard let self else { return }
      self.documentURL = newURL
      self.activeController.fileURL = newURL
      self.restyleAll()  // relative images resolve against the new folder
    }
    f.onDelete = { [weak self] in
      guard let self else { return }
      self.updateDirty()
      self.hooks.onError(.fileDeleted(f.url))
    }
    f.watching = watch
    updateDirty()
  }

  /// Dirty = the buffer differs from what's on disk (so undoing back to it is clean).
  func updateDirty() {
    guard let file else { return }
    let dirty: Bool
    if let disk = file.diskText {
      dirty = (disk as NSString).length != storage.length || disk != storage.string
    } else {
      dirty = true
    }
    if activeController.isDirty != dirty { activeController.isDirty = dirty }
  }

  func save() throws {
    guard let file else { return }
    try file.write(storage.string)
    updateDirty()
  }

  /// Discard edits and show the file as it is on disk.
  func reloadFromDisk() throws {
    guard let file else { return }
    let text = try file.read()
    file.diskText = text
    setExternalText(text)
    updateDirty()
  }

  func setWatching(_ on: Bool) {
    guard let file, file.watching != on else { return }
    file.watching = on
    // Catch up on whatever changed while we weren't looking.
    if on { externalChange() }
  }

  /// Another app changed the file: reload a clean buffer, ask about a dirty one.
  func externalChange() {
    guard let file, file.watching, let disk = try? file.read() else { return }
    if disk == file.diskText, !conflictOpen { return }  // metadata only, or our own write
    let buffer = storage.string
    if disk == buffer {
      file.diskText = disk
      pendingDisk = nil
      updateDirty()
      return
    }
    if file.diskText == buffer, !conflictOpen {
      file.diskText = disk
      setExternalText(disk)
      updateDirty()
      return
    }
    pendingDisk = disk
    guard !conflictOpen else { return }  // the open prompt will use the newest text
    conflictOpen = true
    askAboutConflict()
  }

  private func askAboutConflict() {
    guard let file, let disk = pendingDisk else { return }
    if let hook = hooks.resolveExternalChange {
      Task { @MainActor in
        self.finishConflict(await hook(ExternalChange(url: file.url, diskText: disk)))
      }
      return
    }
    guard let window = textView.window else { return finishConflict(.keepMine) }
    let alert = NSAlert()
    alert.messageText = "“\(file.url.lastPathComponent)” was changed by another application."
    alert.informativeText =
      "Reload it and lose your unsaved changes, or keep your version? Saving later overwrites the other change."
    alert.addButton(withTitle: "Keep My Changes")
    alert.addButton(withTitle: "Reload")
    alert.beginSheetModal(for: window) { [weak self] response in
      MainActor.assumeIsolated {
        self?.finishConflict(response == .alertSecondButtonReturn ? .reload : .keepMine)
      }
    }
  }

  func finishConflict(_ choice: ExternalChangeChoice) {
    conflictOpen = false
    guard let file, let disk = pendingDisk else { return }
    pendingDisk = nil
    file.diskText = disk
    if choice == .reload { setExternalText(disk) }
    updateDirty()
  }
}

extension EditorCoordinator {
  /// The controller the host gave, or the editor's own (the outline needs one).
  var activeController: MarkdownEditorController { controller ?? ownController }

  func setOutline(_ position: OutlinePosition) {
    guard position != container.position || (position != .hidden && outlineHost == nil) else {
      return
    }
    if position != .hidden, outlineHost == nil {
      outlineHost = NSHostingView(rootView: MarkdownOutline(controller: activeController))
    }
    container.setOutline(position == .hidden ? nil : outlineHost, position: position)
  }
}
