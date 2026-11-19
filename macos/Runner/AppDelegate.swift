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

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}