import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    // Cold-start URLs (matrix: links, share-inbox handoff from the Share
    // Extension). Queued before Flutter attaches; Dart pulls on listen.
    for context in connectionOptions.urlContexts {
      ParallaxAppleChannels.handleIncomingURL(context.url)
    }
    super.scene(scene, willConnectTo: session, options: connectionOptions)
  }

  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    // Warm URL opens while the app is running.
    for context in URLContexts {
      ParallaxAppleChannels.handleIncomingURL(context.url)
    }
    // Forward to Flutter/plugins as usual (flutter_web_auth_2 etc.).
    super.scene(scene, openURLContexts: URLContexts)
  }
}