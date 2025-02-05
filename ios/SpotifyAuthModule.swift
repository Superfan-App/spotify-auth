import ExpoModulesCore
import SpotifyiOS

let spotifyAuthorizationEventName = "onSpotifyAuth"

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
    @Field var showDialog: Bool = false
    @Field var campaign: String?
}

// Define a private enum for mapping Spotify SDK error codes.
// (The raw values here are examples; adjust them to match your SDK's definitions.)
private enum SPTErrorCode: Int {
    case authorizationFailed = 100
    case renewSessionFailed = 101
    case jsonFailed = 102
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
            "AuthEventName": spotifyAuthorizationEventName
        ])

        // Defines event names that the module can send to JavaScript.
        Events(spotifyAuthorizationEventName)

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
            
            do {
                try self.spotifyAuth.initAuth(config: config)
                promise.resolve()
            } catch {
                // Sanitize error message.
                let sanitizedError = self.sanitizeErrorMessage(error.localizedDescription)
                secureLog("Auth initialization failed: \(sanitizedError)")
                promise.reject(SpotifyAuthError.authenticationFailed(sanitizedError))
            }
        }

        // Enables the module to be used as a native view.
        View(SpotifyOAuthView.self) {
            Events(spotifyAuthorizationEventName)
            
            Prop("name") { (view: SpotifyOAuthView, _: String) in
                DispatchQueue.main.async {
                    secureLog("View prop updated")
                }
            }
            
            OnViewDidMount { view in
                DispatchQueue.main.async {
                    secureLog("OAuth view loaded")
                }
            }
            
            OnLayout { view in
                DispatchQueue.main.async {
                    secureLog("OAuth view layout updated")
                }
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
        sendEvent(spotifyAuthorizationEventName, eventData)
    }

    @objc
    public func onSignOut() {
        secureLog("User signed out")
        let eventData: [String: Any] = [
            "success": true,
            "token": NSNull(),  // Use NSNull() instead of nil.
            "error": NSNull()   // Use NSNull() instead of nil.
        ]
        sendEvent(spotifyAuthorizationEventName, eventData)
    }

    @objc
    public func onAuthorizationError(_ error: Error) {
        let errorData: [String: Any]
        
        if let spotifyError = error as? SpotifyAuthError {
            // Map domain error to a structured format
            errorData = mapSpotifyError(spotifyError)
        } else if let sptError = error as? SPTError {
            // Map Spotify SDK errors
            errorData = mapSPTError(sptError)
        } else {
            // Map unknown errors
            errorData = [
                "type": "unknown_error",
                "message": sanitizeErrorMessage(error.localizedDescription),
                "details": [
                    "error_code": "unknown",
                    "recoverable": false
                ]
            ]
        }
        
        secureLog("Authorization error: \(errorData["message"] as? String ?? "Unknown error")")
        
        let eventData: [String: Any] = [
            "success": false,
            "token": NSNull(),
            "error": errorData
        ]
        sendEvent(spotifyAuthorizationEventName, eventData)
    }

    private func mapSpotifyError(_ error: SpotifyAuthError) -> [String: Any] {
        let message = sanitizeErrorMessage(error.localizedDescription)
        var details: [String: Any] = ["recoverable": error.isRecoverable]
        
        let (type, errorCode) = classifySpotifyError(error)
        details["error_code"] = errorCode
        
        // Add retry strategy information if available
        switch error.retryStrategy {
        case .retry(let attempts, let delay):
            details["retry"] = [
                "type": "fixed",
                "attempts": attempts,
                "delay": delay
            ]
        case .exponentialBackoff(let maxAttempts, let initialDelay):
            details["retry"] = [
                "type": "exponential",
                "max_attempts": maxAttempts,
                "initial_delay": initialDelay
            ]
        case .none:
            details["retry"] = nil
        }
        
        return [
            "type": type,
            "message": message,
            "details": details
        ]
    }

    private func mapSPTError(_ error: SPTError) -> [String: Any] {
        let message = sanitizeErrorMessage(error.localizedDescription)
        let details: [String: Any] = [
            "error_code": error.code,
            "recoverable": false
        ]
        
        let type: String
        switch error.code {
        case SPTErrorCode.authorizationFailed.rawValue:
            type = "authorization_error"
        case SPTErrorCode.renewSessionFailed.rawValue:
            type = "token_error"
        case SPTErrorCode.jsonFailed.rawValue:
            type = "server_error"
        default:
            type = "unknown_error"
        }
        
        return [
            "type": type,
            "message": message,
            "details": details
        ]
    }

    private func classifySpotifyError(_ error: SpotifyAuthError) -> (type: String, code: String) {
        switch error {
        case .missingConfiguration, .invalidConfiguration:
            return ("configuration_error", "config_invalid")
        case .authenticationFailed:
            return ("authorization_error", "auth_failed")
        case .tokenError:
            return ("token_error", "token_invalid")
        case .sessionError:
            return ("authorization_error", "session_error")
        case .networkError:
            return ("network_error", "network_failed")
        case .recoverable:
            return ("authorization_error", "recoverable_error")
        }
    }

    func presentWebAuth(_ webAuthView: SpotifyOAuthView) {
        // Ensure we're on the main thread for all UI operations
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.presentWebAuth(webAuthView)
            }
            return
        }
        
        guard let topViewController = UIApplication.shared.currentKeyWindow?.rootViewController?.topMostViewController() else {
            onAuthorizationError(SpotifyAuthError.sessionError("Could not present web authentication"))
            return
        }
        
        // Create and configure container view controller
        let containerVC = UIViewController()
        containerVC.view = webAuthView
        
        // Create navigation controller and configure it
        let navigationController = UINavigationController(rootViewController: containerVC)
        navigationController.modalPresentationStyle = .fullScreen
        
        // Add cancel button
        let cancelButton = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(dismissWebAuthWithCancel))
        containerVC.navigationItem.leftBarButtonItem = cancelButton
        containerVC.navigationItem.title = "Spotify Login"
        
        // Present the web auth view
        topViewController.present(navigationController, animated: true, completion: nil)
    }
    
    @objc private func dismissWebAuthWithCancel() {
        spotifyAuth.webAuthViewDidCancel()
        dismissWebAuth()
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
