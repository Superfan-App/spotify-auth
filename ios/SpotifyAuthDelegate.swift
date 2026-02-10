// ios/SpotifyAuthDelegate.swift

import ExpoModulesCore
import SpotifyiOS

public class SpotifyAuthDelegate: ExpoAppDelegateSubscriber, SPTSessionManagerDelegate {
    let spotifyAuth = SpotifyAuthAuth.shared

    public func sessionManager(manager: SPTSessionManager, didInitiate session: SPTSession) {
        spotifyAuth.sessionManager(manager: manager, didInitiate: session)
    }

    public func sessionManager(manager: SPTSessionManager, didFailWith error: Error) {
        spotifyAuth.sessionManager(manager: manager, didFailWith: error)
    }

    public func sessionManager(manager: SPTSessionManager, didRenew session: SPTSession) {
        spotifyAuth.sessionManager(manager: manager, didRenew: session)
    }

    public func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        return spotifyAuth.application(app, open: url, options: options)
    }

    public func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        spotifyAuth.scene(scene, openURLContexts: URLContexts)
    }
}
