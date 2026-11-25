import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  /// Owns the Parallax MethodChannels for the main window's engine.
  private var parallaxChannels: ParallaxAppleChannels?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // MainMenu.xib (and MainFlutterWindow.awakeFromNib, which registers the
    // plugins) has loaded by this point.
    registerParallaxChannels()
    super.applicationDidFinishLaunching(notification)
  }

  private func registerParallaxChannels() {
    if let controller = mainFlutterWindow?.contentViewController as? FlutterViewController {
      parallaxChannels = ParallaxAppleChannels(
        messenger: controller.registrar(forPlugin: "ParallaxApple").messenger)
      return
    }
    // Defensive: if the window is not awake yet, retry on the next runloop
    // turn rather than dropping the channels.
    DispatchQueue.main.async { [weak self] in
      guard let self = self, self.parallaxChannels == nil,
        let controller = self.mainFlutterWindow?.contentViewController as? FlutterViewController
      else { return }
      self.parallaxChannels = ParallaxAppleChannels(
        messenger: controller.registrar(forPlugin: "ParallaxApple").messenger)
    }
  }

  override func application(_ application: NSApplication, open urls: [URL]) {
    // matrix: scheme links become platform intents; the OIDC redirect
    // scheme is left to flutter_web_auth_2.
    for url in urls {
      ParallaxAppleChannels.handleIncomingURL(url)
    }
    super.application(application, open: urls)
  }

  // Like Messages, closing the window leaves Parallax running in the Dock so
  // notifications keep arriving (MainFlutterWindow hides instead of closing).
  // Quit with Cmd-Q or the Dock menu.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return false
  }

  // Clicking the Dock icon brings the closed window back.
  override func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    if !flag {
      mainFlutterWindow?.makeKeyAndOrderFront(nil)
    }
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}