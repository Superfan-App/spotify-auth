import ExpoModulesCore
import SpotifyiOS

let SPOTIFY_AUTHORIZATION_EVENT_NAME = "onSpotifyAuth"

public class SpotifyAuthModule: Module {
    let spotifyAuth = SpotifyAuth.shared

    // Each module class must implement the definition function. The definition consists of components
    // that describes the module's functionality and behavior.
    // See https://docs.expo.dev/modules/module-api for more details about available components.
    public func definition() -> ModuleDefinition {
        Name("SpotifyAuth")

        OnCreate {
            SpotifyAuth.shared.module = self
        }

        Constants([
            "AuthEventName": SPOTIFY_AUTHORIZATION_EVENT_NAME,
        ])

        // Defines event names that the module can send to JavaScript.
        Events(SPOTIFY_AUTHORIZATION_EVENT_NAME)

        // This will be called when JS starts observing the event.
        OnStartObserving {
            print("OnStartObserving")
            // Add any observers or listeners, if required.
            // In this case, you might not need anything here.
        }

        // This will be called when JS stops observing the event.
        OnStopObserving {
            print("OnStopObserving")
            // Remove any observers or listeners.
        }

        Function("authorize") { (_ playURI: String?) in
            spotifyAuth.initAuth(playURI)
        }

        // Enables the module to be used as a native view. Definition components that are accepted as part of the
        // view definition: Prop, Events.
        View(SpotifyAuthView.self) {
            // Defines a setter for the `name` prop.
            Prop("name") { (_: SpotifyAuthView, prop: String) in
                print(prop)
            }
        }
    }

    @objc
    public func onAccessTokenObtained(_ token: String) {
        sendEvent(SPOTIFY_AUTHORIZATION_EVENT_NAME, ["success": true, "token": token])
    }

    @objc
    public func onSignOut() {
        sendEvent(SPOTIFY_AUTHORIZATION_EVENT_NAME, ["success": true, "token": nil])
    }

    @objc
    public func onAuthorizationError(_ errorDescription: String) {
        sendEvent(SPOTIFY_AUTHORIZATION_EVENT_NAME, ["success": false, "error": errorDescription, "token": nil])
    }
}