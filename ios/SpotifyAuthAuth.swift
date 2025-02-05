import ExpoModulesCore
import SpotifyiOS
import KeychainAccess

extension SPTSession {
    convenience init?(accessToken: String, refreshToken: String, expirationDate: Date) {
        self.init()  // Call the parameterless initializer
        setValue(accessToken, forKey: "accessToken")
        setValue(refreshToken, forKey: "refreshToken")
        setValue(expirationDate, forKey: "expirationDate")
    }
}

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

final class SpotifyAuthAuth: NSObject, SPTSessionManagerDelegate, SpotifyOAuthViewDelegate {
    weak var module: SpotifyAuthModule?
    private var webAuthView: SpotifyOAuthView?
    private var isUsingWebAuth = false
    private var currentConfig: AuthorizeConfig?

    static let shared = SpotifyAuthAuth()

    private var clientID: String {
        get throws {
            guard let config = currentConfig else {
                throw SpotifyAuthError.missingConfiguration("No active configuration")
            }
            guard !config.clientId.isEmpty else {
                throw SpotifyAuthError.missingConfiguration("clientId")
            }
            return config.clientId
        }
    }

    private var redirectURL: URL {
        get throws {
            guard let config = currentConfig else {
                throw SpotifyAuthError.missingConfiguration("No active configuration")
            }
            guard let url = URL(string: config.redirectUrl),
                  url.scheme != nil,
                  url.host != nil else {
                throw SpotifyAuthError.invalidConfiguration("Invalid redirect URL format")
            }
            return url
        }
    }

    private var tokenRefreshURL: String {
        get throws {
            guard let config = currentConfig else {
                throw SpotifyAuthError.missingConfiguration("No active configuration")
            }
            guard !config.tokenRefreshURL.isEmpty else {
                throw SpotifyAuthError.missingConfiguration("tokenRefreshURL")
            }
            return config.tokenRefreshURL
        }
    }

    private var tokenSwapURL: String {
        get throws {
            guard let config = currentConfig else {
                throw SpotifyAuthError.missingConfiguration("No active configuration")
            }
            guard !config.tokenSwapURL.isEmpty else {
                throw SpotifyAuthError.missingConfiguration("tokenSwapURL")
            }
            return config.tokenSwapURL
        }
    }

    private var requestedScopes: SPTScope {
        get throws {
            guard let config = currentConfig else {
                throw SpotifyAuthError.missingConfiguration("No active configuration")
            }
            guard !config.scopes.isEmpty else {
                throw SpotifyAuthError.missingConfiguration("scopes")
            }
            
            var combinedScope: SPTScope = []
            for scopeString in config.scopes {
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
            let redirectUrl = try self.redirectURL
            
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
        let redirectUrl = try self.redirectURL
        return "expo.modules.spotifyauth.\(redirectUrl.scheme ?? "unknown").\(clientID).refresh_token"
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

    public func initAuth(config: AuthorizeConfig) {
        do {
            // Store the current configuration
            self.currentConfig = config
            
            guard let sessionManager = self.sessionManager else {
                throw SpotifyAuthError.sessionError("Session manager not initialized")
            }
            let scopes = try self.requestedScopes
            isAuthenticating = true
            
            // Check if Spotify app is installed
            if sessionManager.isSpotifyAppInstalled {
                // Use app-switch auth
                if config.showDialog {
                    sessionManager.alwaysShowAuthorizationDialog = true
                }
                sessionManager.initiateSession(with: scopes, options: .default, campaign: config.campaign)
            } else {
                // Fall back to web auth
                isUsingWebAuth = true
                let clientId = try self.clientID
                let redirectUrl = try self.redirectURL
                
                // Create and configure web auth view
                let webAuthView = SpotifyOAuthView(appContext: nil)
                webAuthView.delegate = self
                self.webAuthView = webAuthView
                
                // Convert SPTScope to string array for web auth
                let scopeStrings = scopes.scopesToStringArray()
                
                // Start web auth flow
                webAuthView.startOAuthFlow(
                    clientId: clientId,
                    redirectUri: redirectUrl.absoluteString,
                    scopes: scopeStrings
                )
                
                // Notify module to present web auth view
                module?.presentWebAuth(webAuthView)
            }
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
            sessionManager.initiateSession(with: scopes, options: .default, campaign: nil)
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
        case "openid":
            return .openid
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

    // MARK: - SpotifyOAuthViewDelegate
    
    func oauthView(_ view: SpotifyOAuthView, didReceiveCode code: String) {
        // Exchange the code for tokens using token swap URL
        exchangeCodeForToken(code)
        
        // Cleanup web view
        cleanupWebAuth()
    }
    
    func oauthView(_ view: SpotifyOAuthView, didFailWithError error: Error) {
        handleError(error, context: "web_authentication")
        cleanupWebAuth()
    }
    
    func oauthViewDidCancel(_ view: SpotifyOAuthView) {
        module?.onAuthorizationError("User cancelled authentication")
        cleanupWebAuth()
    }
    
    private func cleanupWebAuth() {
        isUsingWebAuth = false
        webAuthView = nil
        currentConfig = nil
        module?.dismissWebAuth()
    }
    
    private func exchangeCodeForToken(_ code: String) {
        guard let tokenSwapURL = try? URL(string: self.tokenSwapURL) else {
            handleError(SpotifyAuthError.invalidConfiguration("Invalid token swap URL"), context: "token_exchange")
            return
        }
        
        var request = URLRequest(url: tokenSwapURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let params = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": try? self.redirectURL.absoluteString,
            "client_id": try? self.clientID
        ].compactMapValues { $0 }
        
        request.httpBody = params
            .map { "\($0)=\($1)" }
            .joined(separator: "&")
            .data(using: .utf8)
        
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                self?.handleError(error, context: "token_exchange")
                return
            }
            
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String,
                  let refreshToken = json["refresh_token"] as? String,
                  let expiresIn = json["expires_in"] as? TimeInterval else {
                self?.handleError(SpotifyAuthError.tokenError("Invalid token response"), context: "token_exchange")
                return
            }
            
            // Create session from token response
            let expirationDate = Date(timeIntervalSinceNow: expiresIn)
            if let session = SPTSession(accessToken: accessToken, refreshToken: refreshToken, expirationDate: expirationDate) {
                DispatchQueue.main.async {
                    self?.currentSession = session
                    self?.module?.onAccessTokenObtained(accessToken)
                }
            }
        }
        
        task.resume()
    }
}

// Helper extension to convert SPTScope to string array
extension SPTScope {
    func scopesToStringArray() -> [String] {
        var scopes: [String] = []
        
        if contains(.playlistReadPrivate) { scopes.append("playlist-read-private") }
        if contains(.playlistReadCollaborative) { scopes.append("playlist-read-collaborative") }
        if contains(.playlistModifyPublic) { scopes.append("playlist-modify-public") }
        if contains(.playlistModifyPrivate) { scopes.append("playlist-modify-private") }
        if contains(.userFollowRead) { scopes.append("user-follow-read") }
        if contains(.userFollowModify) { scopes.append("user-follow-modify") }
        if contains(.userLibraryRead) { scopes.append("user-library-read") }
        if contains(.userLibraryModify) { scopes.append("user-library-modify") }
        if contains(.userReadBirthDate) { scopes.append("user-read-birthdate") }
        if contains(.userReadEmail) { scopes.append("user-read-email") }
        if contains(.userReadPrivate) { scopes.append("user-read-private") }
        if contains(.userTopRead) { scopes.append("user-top-read") }
        if contains(.ugcImageUpload) { scopes.append("ugc-image-upload") }
        if contains(.streaming) { scopes.append("streaming") }
        if contains(.appRemoteControl) { scopes.append("app-remote-control") }
        if contains(.userReadPlaybackState) { scopes.append("user-read-playback-state") }
        if contains(.userModifyPlaybackState) { scopes.append("user-modify-playback-state") }
        if contains(.userReadCurrentlyPlaying) { scopes.append("user-read-currently-playing") }
        if contains(.userReadRecentlyPlayed) { scopes.append("user-read-recently-played") }
        if contains(.openid) { scopes.append("openid") }
        
        return scopes
    }
}
