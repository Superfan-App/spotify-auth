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
private enum SPTErrorCode: UInt {
    case unknown = 0
    case authorizationFailed = 1
    case renewSessionFailed = 2
    case jsonFailed = 3
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
            
            Prop("name") { (_: SpotifyOAuthView, _: String) in
                DispatchQueue.main.async {
                    secureLog("View prop updated")
                }
            }
        }
    }

    private func sanitizeErrorMessage(_ message: String) -> String {
        // Only redact actual sensitive values, not general terms
        let sensitivePatterns = [
            "(?i)client[_-]?id=[^&\\s]+",
            "(?i)access_token=[^&\\s]+",
            "(?i)refresh_token=[^&\\s]+",
            "(?i)secret=[^&\\s]+",
            "(?i)api[_-]?key=[^&\\s]+"
        ]
        
        var sanitized = message
        for pattern in sensitivePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                sanitized = regex.stringByReplacingMatches(
                    in: sanitized,
                    range: NSRange(sanitized.startIndex..., in: sanitized),
                    withTemplate: "$1[REDACTED]"
                )
            }
        }
        return sanitized
    }

    @objc
    public func onAccessTokenObtained(_ token: String, refreshToken: String, expiresIn: TimeInterval, scope: String?, tokenType: String) {
        secureLog("Access token obtained", sensitive: true)
        let eventData: [String: Any] = [
            "success": true,
            "token": token,
            "refreshToken": refreshToken,
            "expiresIn": expiresIn,
            "tokenType": tokenType,
            "scope": scope as Any,
            "error": NSNull()  // Use NSNull() instead of nil.
        ]
        sendEvent(spotifyAuthorizationEventName, eventData)
    }

    @objc
    public func onSignOut() {
        secureLog("User signed out")
        let eventData: [String: Any] = [
            "success": true,
            "token": NSNull(),
            "refreshToken": NSNull(),
            "expiresIn": NSNull(),
            "tokenType": NSNull(),
            "scope": NSNull(),
            "error": NSNull()
        ]
        sendEvent(spotifyAuthorizationEventName, eventData)
    }

    @objc
    public func onAuthorizationError(_ error: Error) {
        // Skip sending error events for expected state transitions
        if let spotifyError = error as? SpotifyAuthError,
           case .sessionError(let message) = spotifyError,
           message.contains("authentication process") || 
           message.contains("token exchange") {
            // This is likely a state transition, not an error
            secureLog("Auth state transition: \(message)")
            return
        }
        
        let errorData: [String: Any]
        
        if let spotifyError = error as? SpotifyAuthError {
            errorData = mapSpotifyError(spotifyError)
        } else if let sptError = error as? SPTError {
            errorData = mapSPTError(sptError)
        } else {
            errorData = [
                "type": "unknown_error",
                "message": sanitizeErrorMessage(error.localizedDescription),
                "details": [
                    "error_code": "unknown",
                    "recoverable": false,
                    "error_type": String(describing: type(of: error))
                ]
            ]
        }
        
        secureLog("Authorization error: \(errorData["message"] as? String ?? "Unknown error")")
        
        let eventData: [String: Any] = [
            "success": false,
            "token": NSNull(),
            "refreshToken": NSNull(),
            "expiresIn": NSNull(),
            "tokenType": NSNull(),
            "scope": NSNull(),
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
        var details: [String: Any] = [
            "error_code": error.code,
            "recoverable": false
        ]
        
        // Add underlying error info if available
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error {
            details["underlying_error"] = underlying.localizedDescription
        }
        
        let type: String
        switch SPTErrorCode(rawValue: UInt(error.code)) {
        case .authorizationFailed:
            type = "authorization_error"
            details["recoverable"] = true  // Auth failures are usually recoverable
        case .renewSessionFailed:
            type = "session_error"  // Changed from token_error to be more specific
            details["recoverable"] = true
        case .jsonFailed:
            type = "server_error"
            details["recoverable"] = false
        case .unknown, .none:
            type = "unknown_error"
            details["recoverable"] = false
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
            return ("session_error", "session_error")  // Changed from authorization_error
        case .networkError:
            return ("network_error", "network_failed")
        case .recoverable(let baseError, _):
            // Use the base error type but mark as recoverable in the details
            if let spotifyError = baseError as? SpotifyAuthError {
                let (type, code) = classifySpotifyError(spotifyError)
                return (type, "recoverable_\(code)")
            }
            return ("recoverable_error", "recoverable_unknown")
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
