import ExpoModulesCore
import SpotifyiOS

let SPOTIFY_AUTHORIZATION_EVENT_NAME = "onSpotifyAuth"

#if DEBUG
func secureLog(_ message: String, sensitive: Bool = false) {
    if sensitive {
        print("[SpotifyAuth] ********")
    } else {
        print("[SpotifyAuth] \(message)")
    }
}
#else
func secureLog(_ message: String, sensitive: Bool = false) {
    if !sensitive {
        print("[SpotifyAuth] \(message)")
    }
}
#endif

struct AuthorizeConfig: Record {
    @Field
    var clientId: String
    
    @Field
    var redirectUrl: String
    
    @Field
    var showDialog: Bool = false
}

public class SpotifyAuthModule: Module {
    let spotifyAuth = SpotifyAuthAuth.shared

    public func definition() -> ModuleDefinition {
        Name("SpotifyAuth")

        OnCreate {
            SpotifyAuthAuth.shared.module = self
            secureLog("Module initialized")
        }

        Constants([
            "AuthEventName": SPOTIFY_AUTHORIZATION_EVENT_NAME,
        ])

        // Defines event names that the module can send to JavaScript.
        Events(SPOTIFY_AUTHORIZATION_EVENT_NAME)

        // Called when JS starts observing the event.
        OnStartObserving {
            secureLog("Started observing events")
        }

        // Called when JS stops observing the event.
        OnStopObserving {
            secureLog("Stopped observing events")
        }

        AsyncFunction("authorize") { (config: AuthorizeConfig, promise: Promise) in
            secureLog("Authorization requested")
            
            // Sanitize and validate redirect URL.
            guard let url = URL(string: config.redirectUrl),
                  url.scheme != nil,
                  url.host != nil else {
                promise.reject(SpotifyAuthError.invalidConfiguration("Invalid redirect URL format"))
                return
            }
            
            // Create a configuration (this example does not use the variable afterwards).
            let _ = SPTConfiguration(clientID: config.clientId, redirectURL: url)
            
            do {
                try spotifyAuth.initAuth(showDialog: config.showDialog)
                promise.resolve()
            } catch {
                // Sanitize error message.
                let sanitizedError = sanitizeErrorMessage(error.localizedDescription)
                promise.reject(SpotifyAuthError.authenticationFailed(sanitizedError))
            }
        }

        // Enables the module to be used as a native view.
        View(SpotifyAuthView.self) {
            Prop("name") { (_: SpotifyAuthView, prop: String) in
                secureLog("View prop updated: \(prop)")
            }
        }
    }

    private func sanitizeErrorMessage(_ message: String) -> String {
        // Remove potential sensitive data from error messages.
        let sensitivePatterns = [
            "(?i)client[_-]?id",
            "(?i)token",
            "(?i)secret",
            "(?i)key",
            "(?i)auth",
            "(?i)password"
        ]
        
        var sanitized = message
        for pattern in sensitivePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                sanitized = regex.stringByReplacingMatches(
                    in: sanitized,
                    range: NSRange(sanitized.startIndex..., in: sanitized),
                    withTemplate: "[REDACTED]"
                )
            }
        }
        return sanitized
    }

    @objc
    public func onAccessTokenObtained(_ token: String) {
        secureLog("Access token obtained", sensitive: true)
        let eventData: [String: Any] = [
            "success": true,
            "token": token,
            "error": NSNull()  // Use NSNull() instead of nil.
        ]
        sendEvent(SPOTIFY_AUTHORIZATION_EVENT_NAME, eventData)
    }

    @objc
    public func onSignOut() {
        secureLog("User signed out")
        let eventData: [String: Any] = [
            "success": true,
            "token": NSNull(),  // Use NSNull() instead of nil.
            "error": NSNull()   // Use NSNull() instead of nil.
        ]
        sendEvent(SPOTIFY_AUTHORIZATION_EVENT_NAME, eventData)
    }

    @objc
    public func onAuthorizationError(_ errorDescription: String) {
        let sanitizedError = sanitizeErrorMessage(errorDescription)
        secureLog("Authorization error: \(sanitizedError)")
        let eventData: [String: Any] = [
            "success": false,
            "token": NSNull(),  // Use NSNull() instead of nil.
            "error": sanitizedError
        ]
        sendEvent(SPOTIFY_AUTHORIZATION_EVENT_NAME, eventData)
    }
}
