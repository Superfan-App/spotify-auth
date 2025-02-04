import ExpoModulesCore
import SpotifyiOS

let SPOTIFY_AUTHORIZATION_EVENT_NAME = "onSpotifyAuth"

public class SpotifyAuthModule: Module {
    let spotifyAuth = SpotifyAuthAuth.shared

    // Each module class must implement the definition function. The definition consists of components
    // that describes the module's functionality and behavior.
    // See https://docs.expo.dev/modules/module-api for more details about available components.
    public func definition() -> ModuleDefinition {
        Name("SpotifyAuth")

        OnCreate {
            SpotifyAuthAuth.shared.module = self
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

        @objc(authorize:resolver:rejecter:)
        func authorize(_ config: NSDictionary,
                      resolver resolve: @escaping RCTPromiseResolveBlock,
                      rejecter reject: @escaping RCTPromiseRejectBlock) -> Void {
            guard let clientId = config["clientId"] as? String,
                  let redirectUrl = config["redirectUrl"] as? String else {
                reject("invalid_config", "Missing clientId or redirectUrl", nil)
                return
            }
            
            let showDialog = config["showDialog"] as? Bool ?? false
            
            let configuration = SPTConfiguration(clientID: clientId, redirectURL: URL(string: redirectUrl)!)
            
            spotifyAuth.initAuth(configuration)
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