import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    // Below this the compact (phone) layout is cramped; the adaptive shell
    // switches to master-detail above 600 pt shortest side.
    self.contentMinSize = NSSize(width: 480, height: 420)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  /// The close button, Cmd-W and window_manager's close() hide the window
  /// instead of closing it: the Flutter engine and its Matrix sync keep
  /// running, so notifications still arrive, and the Dock icon or a
  /// notification brings the same window back. Quitting is Cmd-Q.
  override func close() {
    if styleMask.contains(.fullScreen) {
      // Ordering out a full-screen window would leave its empty Space
      // behind; hide the app instead (the Dock icon brings it back).
      NSApp.hide(nil)
    } else {
      orderOut(nil)
    }
  }
}
