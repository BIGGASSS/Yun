import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var startupChannel: FlutterMethodChannel?
  private var dataDirectoryChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    // Dart defers its first frame while configuring. Keep the window/engine
    // active but transparent until Dart reports that frame has rasterized.
    alphaValue = 0
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
      // A channel/configuration failure must not leave the window invisible.
      self?.alphaValue = 1
    }

    var windowFrame = self.frame
    windowFrame.size = NSSize(width: 1280, height: 720)
    if let workArea = NSScreen.screens.first?.visibleFrame {
      let width = min(1280, workArea.width * 0.9)
      let height = min(720, workArea.height * 0.9)
      windowFrame = NSRect(
        x: workArea.midX - width / 2,
        y: workArea.midY - height / 2,
        width: width,
        height: height
      )
    }
    // Fit the outer frame in points before creating the Flutter controller.
    self.setFrame(windowFrame, display: false)

    let flutterViewController = FlutterViewController()
    startupChannel = FlutterMethodChannel(
      name: "yun/desktop_startup",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    startupChannel?.setMethodCallHandler { [weak self] call, result in
      if call.method == "ready" {
        self?.alphaValue = 1
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    dataDirectoryChannel = FlutterMethodChannel(
      name: "yun/data_directory",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    dataDirectoryChannel?.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "restoreAccess":
        result(DataDirectoryAccess.shared.restoreAccess())
      case "pickDirectory":
        guard let window = self else {
          result(FlutterError(code: "window_unavailable", message: "No picker window", details: nil))
          return
        }
        let arguments = call.arguments as? [String: Any]
        DataDirectoryAccess.shared.pickDirectory(
          initialDirectory: arguments?["initialDirectory"] as? String,
          window: window,
          result: result
        )
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.title = "韵"

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}

/// Process-wide, not window-owned: both the active root and a pending migration
/// target must remain accessible until exit. Keep the small set of old grants
/// too, so cancelling/recovering a move does not revoke its source.
private final class DataDirectoryAccess {
  static let shared = DataDirectoryAccess()

  private let defaults = UserDefaults.standard
  private let bookmarksKey = "yun.dataDirectory.securityScopedBookmarks.v1"
  private var scopedURLs: [String: URL] = [:]
  private var openPanel: NSOpenPanel?

  private init() {}

  func restoreAccess() -> [String] {
    guard let bookmarks = defaults.dictionary(forKey: bookmarksKey) else {
      return defaults.object(forKey: bookmarksKey) == nil
        ? [] : ["Invalid saved data-directory bookmarks"]
    }
    var warnings: [String] = []
    for (path, value) in bookmarks {
      guard let bookmark = value as? Data else {
        warnings.append("Invalid data-directory bookmark: \(path)")
        continue
      }
      do {
        var stale = false
        let url = try URL(
          resolvingBookmarkData: bookmark,
          options: [.withSecurityScope, .withoutUI],
          relativeTo: nil,
          bookmarkDataIsStale: &stale
        )
        try retainAccess(to: url)
        if stale {
          // Refresh while access is held. Failure must not release the usable
          // scope or stop restoration of other (possibly current) roots.
          let refreshed = try makeBookmark(for: url)
          try saveBookmark(refreshed, for: path)
        }
      } catch {
        warnings.append("\(path): \(error.localizedDescription)")
      }
    }
    // A disconnected/revoked historical grant is not a startup failure. The
    // controller's filesystem checks decide which roots actually need access.
    return warnings
  }

  func pickDirectory(
    initialDirectory: String?, window: NSWindow, result: @escaping FlutterResult
  ) {
    guard openPanel == nil else {
      result(FlutterError(code: "picker_busy", message: "A folder picker is already open", details: nil))
      return
    }
    let panel = NSOpenPanel()
    panel.title = "Choose data directory"
    panel.message = "Choose data directory"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    if let initialDirectory = initialDirectory, !initialDirectory.isEmpty {
      panel.directoryURL = URL(fileURLWithPath: initialDirectory, isDirectory: true)
    }
    openPanel = panel
    panel.beginSheetModal(for: window) { response in
      self.openPanel = nil
      guard response == .OK, let selection = panel.url else {
        result(nil)
        return
      }
      do {
        let bookmark = try self.makeBookmark(for: selection)
        var stale = false
        let url = try URL(
          resolvingBookmarkData: bookmark,
          options: [.withSecurityScope, .withoutUI],
          relativeTo: nil,
          bookmarkDataIsStale: &stale
        )
        try self.retainAccess(to: url)
        var currentBookmark = bookmark
        if stale {
          currentBookmark = try self.makeBookmark(for: url)
        }
        try self.saveBookmark(currentBookmark, for: url.path)
        // Never report a selection whose grant could not be saved. Keeping a
        // scope after a failed save is harmless; no data-root change succeeded.
        result(url.path)
      } catch {
        result(FlutterError(
          code: "data_directory_access_failed", message: error.localizedDescription, details: nil
        ))
      }
    }
  }

  private func makeBookmark(for url: URL) throws -> Data {
    // Deliberately omit securityScopeAllowOnlyReadAccess: migration writes both
    // roots and the data directory will also contain SQLite databases.
    return try url.bookmarkData(
      options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
    )
  }

  private func retainAccess(to url: URL) throws {
    if scopedURLs[url.path] != nil { return }
    guard url.startAccessingSecurityScopedResource() else {
      throw NSError(
        domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
        userInfo: [NSLocalizedDescriptionKey: "Cannot access data directory: \(url.path)"]
      )
    }
    // Intentionally do not stopAccessingSecurityScopedResource: Dart performs
    // asynchronous I/O long after the panel/restoration callback returns. The
    // singleton retains these URLs and the OS releases scopes at process exit.
    scopedURLs[url.path] = url
  }

  private func saveBookmark(_ bookmark: Data, for path: String) throws {
    var bookmarks = defaults.dictionary(forKey: bookmarksKey) ?? [:]
    bookmarks[path] = bookmark
    defaults.set(bookmarks, forKey: bookmarksKey)
    // set() alone only updates the preferences cache. Require an acknowledged
    // flush and verify the whole set (including earlier active/pending grants).
    // This is UserDefaults' durability boundary, not an fsync/power-loss promise.
    guard defaults.synchronize(),
      let saved = defaults.dictionary(forKey: bookmarksKey),
      NSDictionary(dictionary: bookmarks).isEqual(NSDictionary(dictionary: saved))
    else {
      throw NSError(
        domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
        userInfo: [NSLocalizedDescriptionKey: "Could not persist data-directory access"]
      )
    }
  }
}
