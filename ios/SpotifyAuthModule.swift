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

    @Field
    var campaign: String?
    
    @Field
    var tokenSwapURL: String
    
    @Field
    var tokenRefreshURL: String
    
    @Field
    var scopes: [String]
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
            
            do {
                try spotifyAuth.initAuth(config: config)
                promise.resolve()
            } catch {
                // Sanitize error message.
                let sanitizedError = sanitizeErrorMessage(error.localizedDescription)
                promise.reject(SpotifyAuthError.authenticationFailed(sanitizedError))
            }
        }

        // Enables the module to be used as a native view.
        View(SpotifyOAuthView.self) {
            Prop("name") { (_: SpotifyOAuthView, prop: String) in
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

    func presentWebAuth(_ webAuthView: SpotifyOAuthView) {
        guard let topViewController = UIApplication.shared.currentKeyWindow?.rootViewController?.topMostViewController() else {
            onAuthorizationError("Could not present web authentication")
            return
        }
        
        // Create and configure container view controller
        let containerVC = UIViewController()
        containerVC.view = webAuthView
        containerVC.modalPresentationStyle = .fullScreen
        
        // Present the web auth view
        DispatchQueue.main.async {
            topViewController.present(containerVC, animated: true, completion: nil)
        }
    }
    
    func dismissWebAuth() {
        // Find and dismiss the web auth view controller
        DispatchQueue.main.async {
            UIApplication.shared.currentKeyWindow?.rootViewController?.topMostViewController().dismiss(animated: true)
        }
    }
}

// Helper extension to find top-most view controller
extension UIViewController {
    func topMostViewController() -> UIViewController {
        if let presented = presentedViewController {
            return presented.topMostViewController()
        }
        if let navigation = self as? UINavigationController {
            return navigation.visibleViewController?.topMostViewController() ?? navigation
        }
        if let tab = self as? UITabBarController {
            return tab.selectedViewController?.topMostViewController() ?? tab
        }
        return self
    }
}

// Extension to safely get key window on iOS 13+
extension UIApplication {
    var currentKeyWindow: UIWindow? {
        if #available(iOS 13, *) {
            return self.connectedScenes
                .filter { $0.activationState == .foregroundActive }
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first(where: { $0.isKeyWindow })
        } else {
            return self.keyWindow
        }
    }
}
