import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var startupChannel: FlutterMethodChannel?

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

    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.title = "韵"

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
