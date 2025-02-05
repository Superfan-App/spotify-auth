import ExpoModulesCore
import SpotifyiOS
import KeychainAccess

enum SpotifyAuthError: Error {
    case missingConfiguration(String)
    case invalidConfiguration(String)
    case authenticationFailed(String)
    case tokenError(String)
    case sessionError(String)
    case networkError(String)
    case recoverable(String, RetryStrategy)
    
    enum RetryStrategy {
        case none
        case retry(attempts: Int, delay: TimeInterval)
        case exponentialBackoff(maxAttempts: Int, initialDelay: TimeInterval)
    }
    
    var isRecoverable: Bool {
        switch self {
        case .recoverable:
            return true
        case .networkError:
            return true
        case .tokenError:
            return true
        default:
            return false
        }
    }
    
    var localizedDescription: String {
        switch self {
        case .missingConfiguration(let field):
            return "Missing configuration: \(field). Please check your app.json configuration."
        case .invalidConfiguration(let reason):
            return "Invalid configuration: \(reason). Please verify your settings."
        case .authenticationFailed(let reason):
            return "Authentication failed: \(reason). Please try again."
        case .tokenError(let reason):
            return "Token error: \(reason). Please try logging in again."
        case .sessionError(let reason):
            return "Session error: \(reason). Please restart the authentication process."
        case .networkError(let reason):
            return "Network error: \(reason). Please check your internet connection."
        case .recoverable(let message, _):
            return message
        }
    }
    
    var retryStrategy: RetryStrategy {
        switch self {
        case .recoverable(_, let strategy):
            return strategy
        case .networkError:
            return .exponentialBackoff(maxAttempts: 3, initialDelay: 1.0)
        case .tokenError:
            return .retry(attempts: 3, delay: 5.0)
        default:
            return .none
        }
    }
}

final class SpotifyAuthAuth: NSObject, SPTSessionManagerDelegate {
    weak var module: SpotifyAuthModule?

    static let shared = SpotifyAuthAuth()

    private var clientID: String {
        get throws {
            guard let value = Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String,
                  !value.isEmpty else {
                throw SpotifyAuthError.missingConfiguration("clientID")
            }
            return value
        }
    }

    private var scheme: String {
        get throws {
            guard let value = Bundle.main.object(forInfoDictionaryKey: "SpotifyScheme") as? String,
                  !value.isEmpty else {
                throw SpotifyAuthError.missingConfiguration("scheme")
            }
            return value
        }
    }

    private var callback: String {
        get throws {
            guard let value = Bundle.main.object(forInfoDictionaryKey: "SpotifyCallback") as? String,
                  !value.isEmpty else {
                throw SpotifyAuthError.missingConfiguration("callback")
            }
            return value
        }
    }

    private var tokenRefreshURL: String {
        get throws {
            guard let value = Bundle.main.object(forInfoDictionaryKey: "tokenRefreshURL") as? String,
                  !value.isEmpty else {
                throw SpotifyAuthError.missingConfiguration("tokenRefreshURL")
            }
            return value
        }
    }

    private var tokenSwapURL: String {
        get throws {
            guard let value = Bundle.main.object(forInfoDictionaryKey: "tokenSwapURL") as? String,
                  !value.isEmpty else {
                throw SpotifyAuthError.missingConfiguration("tokenSwapURL")
            }
            return value
        }
    }

    private var requestedScopes: SPTScope {
        get throws {
            guard let scopeStrings = Bundle.main.object(forInfoDictionaryKey: "SpotifyScopes") as? [String],
                  !scopeStrings.isEmpty else {
                throw SpotifyAuthError.missingConfiguration("scopes")
            }
            
            var combinedScope: SPTScope = []
            for scopeString in scopeStrings {
                if let scope = stringToScope(scopeString: scopeString) {
                    combinedScope.insert(scope)
                }
            }
            
            if combinedScope.isEmpty {
                throw SpotifyAuthError.invalidConfiguration("No valid scopes provided")
            }
            
            return combinedScope
        }
    }

    private func validateAndConfigureURLs(_ config: SPTConfiguration) throws {
        // Validate token swap URL
        guard let tokenSwapURL = URL(string: try self.tokenSwapURL),
              tokenSwapURL.scheme?.lowercased() == "https" else {
            throw SpotifyAuthError.invalidConfiguration("Token swap URL must use HTTPS")
        }
        
        // Validate token refresh URL
        guard let tokenRefreshURL = URL(string: try self.tokenRefreshURL),
              tokenRefreshURL.scheme?.lowercased() == "https" else {
            throw SpotifyAuthError.invalidConfiguration("Token refresh URL must use HTTPS")
        }
        
        config.tokenSwapURL = tokenSwapURL
        config.tokenRefreshURL = tokenRefreshURL
        
        // Configure session for secure communication
        let session = URLSession(configuration: .ephemeral)
        session.configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        session.configuration.httpAdditionalHeaders = [
            "X-Client-ID": try self.clientID // Add secure client identification
        ]
    }

    lazy var configuration: SPTConfiguration? = {
        do {
            let clientID = try self.clientID
            let scheme = try self.scheme
            let callback = try self.callback
            
            guard let redirectUrl = URL(string: "\(scheme)://\(callback)") else {
                throw SpotifyAuthError.invalidConfiguration("Invalid redirect URL formation")
            }
            
            let config = SPTConfiguration(clientID: clientID, redirectURL: redirectUrl)
            try validateAndConfigureURLs(config)
            
            return config
        } catch {
            module?.onAuthorizationError(error.localizedDescription)
            return nil
        }
    }()

    lazy var sessionManager: SPTSessionManager? = {
        guard let configuration = self.configuration else {
            module?.onAuthorizationError("Failed to create configuration")
            return nil
        }
        return SPTSessionManager(configuration: configuration, delegate: self)
    }()

    private var currentSession: SPTSession? {
        didSet {
            cleanupPreviousSession()
            if let session = currentSession {
                securelyStoreToken(session)
                scheduleTokenRefresh(session)
            }
        }
    }
    
    private var isAuthenticating: Bool = false {
        didSet {
            if !isAuthenticating && currentSession == nil {
                module?.onAuthorizationError("Authentication process ended without session")
            }
        }
    }

    private var refreshTimer: Timer?

    private func scheduleTokenRefresh(_ session: SPTSession) {
        refreshTimer?.invalidate()
        
        // Schedule refresh 5 minutes before expiration
        let refreshInterval = TimeInterval(session.expirationDate.timeIntervalSinceNow - 300)
        if refreshInterval > 0 {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: false) { [weak self] _ in
                self?.refreshToken()
            }
        } else {
            refreshToken()
        }
    }

    private func getKeychainKey() throws -> String {
        let clientID = try self.clientID
        let scheme = try self.scheme
        return "expo.modules.spotifyauth.\(scheme).\(clientID).refresh_token"
    }

    private func securelyStoreToken(_ session: SPTSession) {
        // Pass token to JS and securely store refresh token
        module?.onAccessTokenObtained(session.accessToken)
        
        // Since refreshToken is now a non-optional String, we simply check for an empty value.
        let refreshToken = session.refreshToken
        if !refreshToken.isEmpty {
            do {
                let keychainKey = try getKeychainKey()
                // Create a Keychain instance (using bundle identifier as the service)
                let keychain = Keychain(service: Bundle.main.bundleIdentifier ?? "com.superfan.app")
                    .accessibility(.afterFirstUnlock)
                try keychain.set(refreshToken, key: keychainKey)
            } catch {
                print("Failed to store refresh token securely: \(error)")
            }
        }
    }

    private func cleanupPreviousSession() {
        refreshTimer?.invalidate()
        
        do {
            let keychainKey = try getKeychainKey()
            let keychain = Keychain(service: Bundle.main.bundleIdentifier ?? "com.superfan.app")
            try keychain.remove(keychainKey)
        } catch {
            print("Failed to clear previous refresh token: \(error)")
        }
        
        // Clear in-memory session data
        currentSession = nil
    }

    private func refreshToken(retryCount: Int = 0) {
        guard let sessionManager = self.sessionManager else {
            handleError(SpotifyAuthError.sessionError("Session manager not available"), context: "token_refresh")
            return
        }
        
        do {
            try sessionManager.renewSession()
        } catch {
            handleError(error, context: "token_refresh")
        }
    }

    public func initAuth(showDialog: Bool = false, campaign: String? = nil) {
        do {
            guard let sessionManager = self.sessionManager else {
                throw SpotifyAuthError.sessionError("Session manager not initialized")
            }
            let scopes = try self.requestedScopes
            isAuthenticating = true
            
            // If showDialog is true, we want to force the authorization dialog
            // This is different from clientOnly which would force using Spotify app
            if showDialog {
                sessionManager.alwaysShowAuthorizationDialog = true
            }
            
            // Use default authorization which will automatically choose the best method
            // (Spotify app if installed, web view if not)
            sessionManager.initiateSessionWithScope(scopes, options: .default, campaign: campaign)
        } catch {
            isAuthenticating = false
            handleError(error, context: "authentication")
        }
    }

    private func retryAuthentication() {
        guard !isAuthenticating else { return }
        
        do {
            guard let sessionManager = self.sessionManager else {
                throw SpotifyAuthError.sessionError("Session manager not initialized")
            }
            let scopes = try self.requestedScopes
            isAuthenticating = true
            // Updated: Use .default instead of empty array cast
            sessionManager.initiateSessionWithScope(scopes, options: .default, campaign: nil)
        } catch {
            isAuthenticating = false
            handleError(error, context: "authentication_retry")
        }
    }

    public func sessionManager(manager _: SPTSessionManager, didInitiate session: SPTSession) {
        secureLog("Authentication successful")
        isAuthenticating = false
        currentSession = session
    }

    public func sessionManager(manager _: SPTSessionManager, didFailWith error: Error) {
        secureLog("Authentication failed")
        isAuthenticating = false
        currentSession = nil
        handleError(error, context: "authentication")
    }

    public func sessionManager(manager _: SPTSessionManager, didRenew session: SPTSession) {
        secureLog("Token renewed successfully")
        currentSession = session
    }
    
    public func clearSession() {
        currentSession = nil
        module?.onSignOut()
    }

    private func stringToScope(scopeString: String) -> SPTScope? {
        switch scopeString {
        case "playlist-read-private":
            return .playlistReadPrivate
        case "playlist-read-collaborative":
            return .playlistReadCollaborative
        case "playlist-modify-public":
            return .playlistModifyPublic
        case "playlist-modify-private":
            return .playlistModifyPrivate
        case "user-follow-read":
            return .userFollowRead
        case "user-follow-modify":
            return .userFollowModify
        case "user-library-read":
            return .userLibraryRead
        case "user-library-modify":
            return .userLibraryModify
        case "user-read-birthdate":
            return .userReadBirthDate
        case "user-read-email":
            return .userReadEmail
        case "user-read-private":
            return .userReadPrivate
        case "user-top-read":
            return .userTopRead
        case "ugc-image-upload":
            return .ugcImageUpload
        case "streaming":
            return .streaming
        case "app-remote-control":
            return .appRemoteControl
        case "user-read-playback-state":
            return .userReadPlaybackState
        case "user-modify-playback-state":
            return .userModifyPlaybackState
        case "user-read-currently-playing":
            return .userReadCurrentlyPlaying
        case "user-read-recently-played":
            return .userReadRecentlyPlayed
        default:
            return nil
        }
    }

    private func handleError(_ error: Error, context: String) {
        let spotifyError: SpotifyAuthError
        
        // Instead of switching on SPTError cases (which are no longer available),
        // we simply wrap the error's description.
        if error is SPTError {
            spotifyError = .authenticationFailed(error.localizedDescription)
        } else {
            spotifyError = .authenticationFailed(error.localizedDescription)
        }
        
        secureLog("Error in \(context): \(spotifyError.localizedDescription)")
        
        switch spotifyError.retryStrategy {
        case .none:
            module?.onAuthorizationError(spotifyError.localizedDescription)
            cleanupPreviousSession()
            
        case .retry(let attempts, let delay):
            handleRetry(error: spotifyError, context: context, remainingAttempts: attempts, delay: delay)
            
        case .exponentialBackoff(let maxAttempts, let initialDelay):
            handleExponentialBackoff(error: spotifyError, context: context, remainingAttempts: maxAttempts, currentDelay: initialDelay)
        }
    }

    private func handleRetry(error: SpotifyAuthError, context: String, remainingAttempts: Int, delay: TimeInterval) {
        guard remainingAttempts > 0 else {
            module?.onAuthorizationError("\(error.localizedDescription) (Max retries reached)")
            cleanupPreviousSession()
            return
        }
        
        secureLog("Retrying \(context) in \(delay) seconds. Attempts remaining: \(remainingAttempts)")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            switch context {
            case "token_refresh":
                self?.refreshToken(retryCount: 3 - remainingAttempts)
            case "authentication":
                self?.retryAuthentication()
            default:
                break
            }
        }
    }

    private func handleExponentialBackoff(error: SpotifyAuthError, context: String, remainingAttempts: Int, currentDelay: TimeInterval) {
        guard remainingAttempts > 0 else {
            module?.onAuthorizationError("\(error.localizedDescription) (Max retries reached)")
            cleanupPreviousSession()
            return
        }
        
        secureLog("Retrying \(context) in \(currentDelay) seconds. Attempts remaining: \(remainingAttempts)")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + currentDelay) { [weak self] in
            switch context {
            case "token_refresh":
                self?.refreshToken(retryCount: 3 - remainingAttempts)
            case "authentication":
                self?.retryAuthentication()
            default:
                break
            }
        }
    }

    deinit {
        cleanupPreviousSession()
    }
}
