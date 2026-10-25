import AppKit

/// The open file: coordinated UTF-8 reads and atomic writes, plus an `NSFilePresenter` so
/// other apps' changes, atomic replaces and moves arrive natively, and our own coordinated
/// writes don't echo back.
@MainActor
final class DocumentFile {
  private(set) var url: URL
  /// The text last read from or written to disk; `nil` once the file is gone.
  var diskText: String?
  var onChange: (() -> Void)?
  var onMove: ((URL) -> Void)?
  var onDelete: (() -> Void)?

  private let bridge: FilePresenterBridge
  private var pending: DispatchWorkItem?
  private var activeObserver: NSObjectProtocol?

  var watching = false {
    didSet {
      guard watching != oldValue else { return }
      if watching {
        NSFileCoordinator.addFilePresenter(bridge)
        // Plain `rm` sends presenters nothing; check again whenever the user comes back.
        activeObserver = NotificationCenter.default.addObserver(
          forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.checkStillThere() } }
      } else {
        NSFileCoordinator.removeFilePresenter(bridge)
        activeObserver.map(NotificationCenter.default.removeObserver)
        activeObserver = nil
      }
    }
  }

  init(url: URL) {
    self.url = url
    bridge = FilePresenterBridge(url: url)
    bridge.owner = self
  }

  isolated deinit {
    if watching { NSFileCoordinator.removeFilePresenter(bridge) }
    activeObserver.map(NotificationCenter.default.removeObserver)
  }

  func read() throws -> String {
    var coordinationError: NSError?
    var result: Result<String, Error> = .failure(EditorError.fileUnreadable(url))
    NSFileCoordinator(filePresenter: bridge).coordinate(
      readingItemAt: url, options: [], error: &coordinationError
    ) { u in
      do {
        let data = try Data(contentsOf: u)
        guard let s = String(data: data, encoding: .utf8) else {
          throw EditorError.fileUnreadable(u)
        }
        result = .success(s)
      } catch {
        result = .failure(error is EditorError ? error : EditorError.fileUnreadable(u))
      }
    }
    if coordinationError != nil { throw EditorError.fileUnreadable(url) }
    return try result.get()
  }

  func write(_ text: String) throws {
    var coordinationError: NSError?
    var failure: Error?
    NSFileCoordinator(filePresenter: bridge).coordinate(
      writingItemAt: url, options: .forReplacing, error: &coordinationError
    ) { u in
      do { try Data(text.utf8).write(to: u, options: .atomic) } catch { failure = error }
    }
    if let e = failure ?? coordinationError { throw EditorError.fileWrite(e.localizedDescription) }
    diskText = text
  }

  // MARK: From the presenter (main queue)

  /// Bursts (atomic replace = several events) become one change.
  func presentedChange() {
    pending?.cancel()
    let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.onChange?() } }
    pending = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
  }

  func presentedMove(to newURL: URL) {
    url = newURL
    bridge.presentedItemURL = newURL
    onMove?(newURL)
  }

  func presentedDelete() {
    guard diskText != nil else { return }
    diskText = nil
    onDelete?()
  }

  private func checkStillThere() {
    if !FileManager.default.fileExists(atPath: url.path) { presentedDelete() }
  }
}

/// `NSFilePresenter` needs an NSObject; it forwards to the main-actor `DocumentFile`.
final class FilePresenterBridge: NSObject, NSFilePresenter, @unchecked Sendable {
  // Read by the coordination machinery off the main thread; only written on main.
  nonisolated(unsafe) var presentedItemURL: URL?
  let presentedItemOperationQueue = OperationQueue.main
  nonisolated(unsafe) weak var owner: DocumentFile?

  init(url: URL) { presentedItemURL = url }

  func presentedItemDidChange() {
    MainActor.assumeIsolated { owner?.presentedChange() }
  }

  func presentedItemDidMove(to newURL: URL) {
    MainActor.assumeIsolated { owner?.presentedMove(to: newURL) }
  }

  func accommodatePresentedItemDeletion(completionHandler: @escaping @Sendable (Error?) -> Void) {
    MainActor.assumeIsolated { owner?.presentedDelete() }
    completionHandler(nil)
  }
}
