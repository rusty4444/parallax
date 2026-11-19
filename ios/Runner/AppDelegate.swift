import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Owns the Parallax MethodChannels for the implicit Flutter engine.
  private var parallaxChannels: ParallaxAppleChannels?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Cold-start link when launched without scenes; with the scene manifest
    // the URL arrives via SceneDelegate.scene(_:willConnectTo:options:).
    if let url = launchOptions?[.url] as? URL {
      ParallaxAppleChannels.handleIncomingURL(url)
    }
    // Shares queued by the Share Extension before this process existed.
    // The queue holds them until Dart attaches and pulls.
    ParallaxIntentStore.shared.drainShareInbox()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Register the app channels right after the plugins, on the engine's
    // own messenger (the storyboard FlutterViewController is not attached
    // to a window yet at this point).
    parallaxChannels = ParallaxAppleChannels(
      messenger: engineBridge.applicationRegistrar.messenger())
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    // matrix: / matrix.to links become platform intents; the OIDC redirect
    // scheme is left to flutter_web_auth_2 (its ASWebAuthenticationSession
    // receives the callback directly).
    let handled = ParallaxAppleChannels.handleIncomingURL(url)
    let pluginHandled = super.application(app, open: url, options: options)
    return handled || pluginHandled
  }
}