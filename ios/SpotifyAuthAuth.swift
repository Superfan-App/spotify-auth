import ExpoModulesCore
import SpotifyiOS
import KeychainAccess

/// A lightweight session model to hold token information.
struct SpotifySessionData {
  let accessToken: String
  let refreshToken: String
  let expirationDate: Date
  
  var isExpired: Bool {
    return Date() >= expirationDate
  }
  
  init(accessToken: String, refreshToken: String, expirationDate: Date) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expirationDate = expirationDate
  }
  
  /// Initialize from an SPTSession (from app‑switch flow)
  init?(session: SPTSession) {
    // We assume that SPTSession has valid properties.
    self.accessToken = session.accessToken
    self.refreshToken = session.refreshToken
    self.expirationDate = session.expirationDate
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
  /// A weak reference to our module's JS interface.
  weak var module: SpotifyAuthModule?
  
  /// For web‑auth we present our own OAuth view.
  private var webAuthView: SpotifyOAuthView?
  private var isUsingWebAuth = false
  
  /// Stores the active configuration from JS.
  private var currentConfig: AuthorizeConfig?
  
  /// Our own session model.
  private var currentSession: SpotifySessionData? {
    didSet {
      cleanupPreviousSession()
      if let session = currentSession {
        securelyStoreToken(session)
        scheduleTokenRefresh(session)
      }
    }
  }
  
  /// If authentication is in progress.
  private var isAuthenticating: Bool = false {
    didSet {
      if !isAuthenticating && currentSession == nil {
        module?.onAuthorizationError(SpotifyAuthError.sessionError("Authentication process ended without session"))
      }
    }
  }
  
  private var refreshTimer: Timer?
  
  static let shared = SpotifyAuthAuth()
  
  // MARK: - Configuration Accessors
  
  private func getInfoPlistValue<T>(_ key: String) throws -> T {
    guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? T else {
      throw SpotifyAuthError.missingConfiguration("Missing \(key) in Info.plist")
    }
    return value
  }
  
  private var clientID: String {
    get throws {
      try getInfoPlistValue("SpotifyClientID")
    }
  }
  
  private var redirectURL: URL {
    get throws {
      let urlString: String = try getInfoPlistValue("SpotifyRedirectURL")
      guard let url = URL(string: urlString) else {
        throw SpotifyAuthError.invalidConfiguration("Invalid redirect URL format")
      }
      return url
    }
  }
  
  private var tokenSwapURL: String {
    get throws {
      try getInfoPlistValue("SpotifyTokenSwapURL")
    }
  }
  
  private var tokenRefreshURL: String {
    get throws {
      try getInfoPlistValue("SpotifyTokenRefreshURL")
    }
  }
  
  private var scopes: [String] {
    get throws {
      try getInfoPlistValue("SpotifyScopes")
    }
  }
  
  /// Validate and set up secure URLs on the SPTConfiguration.
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
    
    // Configure secure communication headers.
    let session = URLSession(configuration: .ephemeral)
    session.configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
    session.configuration.httpAdditionalHeaders = [
      "X-Client-ID": try self.clientID
    ]
  }
  
  // MARK: - SPTConfiguration and Session Manager (for app‑switch auth)
  
  lazy var configuration: SPTConfiguration? = {
    do {
      let clientID = try self.clientID
      let redirectUrl = try self.redirectURL
      let config = SPTConfiguration(clientID: clientID, redirectURL: redirectUrl)
      try validateAndConfigureURLs(config)
      return config
    } catch {
      module?.onAuthorizationError(error)
      return nil
    }
  }()
  
  lazy var sessionManager: SPTSessionManager? = {
    guard let configuration = self.configuration else {
      module?.onAuthorizationError(SpotifyAuthError.sessionError("Failed to create configuration"))
      return nil
    }
    return SPTSessionManager(configuration: configuration, delegate: self)
  }()
  
  // MARK: - Session Refresh and Secure Storage
  
  private func scheduleTokenRefresh(_ session: SpotifySessionData) {
    refreshTimer?.invalidate()
    
    // Schedule refresh 5 minutes before expiration.
    let refreshInterval = session.expirationDate.timeIntervalSinceNow - 300
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
  
  private func securelyStoreToken(_ session: SpotifySessionData) {
    // Pass token back to JS.
    module?.onAccessTokenObtained(session.accessToken)
    
    let refreshToken = session.refreshToken
    if !refreshToken.isEmpty {
      do {
        let keychainKey = try getKeychainKey()
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
  }
  
  /// Refresh token either via SPTSessionManager (app‑switch) or manually (web‑auth).
  private func refreshToken(retryCount: Int = 0) {
    if isUsingWebAuth {
      manualRefreshToken(retryCount: retryCount)
    } else {
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
  }
  
  /// Manual refresh (for web‑auth) that calls the token refresh endpoint.
  private func manualRefreshToken(retryCount: Int = 0) {
    guard let currentSession = self.currentSession else {
      handleError(SpotifyAuthError.sessionError("No session available"), context: "token_refresh")
      return
    }
    guard let refreshURLString = try? self.tokenRefreshURL,
          let url = URL(string: refreshURLString) else {
      handleError(SpotifyAuthError.invalidConfiguration("Invalid token refresh URL"), context: "token_refresh")
      return
    }
    
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    
    let params: [String: String]
    do {
      params = [
        "grant_type": "refresh_token",
        "refresh_token": currentSession.refreshToken,
        "client_id": try self.clientID
      ]
    } catch {
      handleError(error, context: "token_refresh")
      return
    }
    
    let bodyString = params.map { "\($0)=\($1)" }.joined(separator: "&")
    request.httpBody = bodyString.data(using: .utf8)
    
    let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      if let error = error {
        self?.handleError(error, context: "token_refresh")
        return
      }
      guard let data = data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = json["access_token"] as? String,
            let expiresIn = json["expires_in"] as? TimeInterval else {
        self?.handleError(SpotifyAuthError.tokenError("Invalid token refresh response"), context: "token_refresh")
        return
      }
      
      let newRefreshToken = (json["refresh_token"] as? String) ?? currentSession.refreshToken
      let expirationDate = Date(timeIntervalSinceNow: expiresIn)
      let newSession = SpotifySessionData(accessToken: accessToken, refreshToken: newRefreshToken, expirationDate: expirationDate)
      DispatchQueue.main.async {
        self?.currentSession = newSession
        self?.module?.onAccessTokenObtained(accessToken)
      }
    }
    task.resume()
  }
  
  // MARK: - Authentication Flow
  
  public func initAuth(config: AuthorizeConfig) {
    do {
        guard let sessionManager = self.sessionManager else {
            throw SpotifyAuthError.sessionError("Session manager not initialized")
        }
        
        // Get scopes from Info.plist and convert to SPTScope
        let scopes = try self.scopes
        let sptScopes = scopes.reduce(into: SPTScope()) { result, scopeString in
            if let scope = stringToScope(scopeString: scopeString) {
                result.insert(scope)
            }
        }
        
        if sptScopes.isEmpty {
            throw SpotifyAuthError.invalidConfiguration("No valid scopes found in configuration")
        }
        
        isAuthenticating = true
        
        if sessionManager.isSpotifyAppInstalled {
            // Use the native app‑switch flow
            if config.showDialog {
                sessionManager.alwaysShowAuthorizationDialog = true
            }
            sessionManager.initiateSession(with: sptScopes, options: .default, campaign: config.campaign)
        } else {
            // Use web auth as fallback
            let webView = SpotifyOAuthView(appContext: nil)
            webView.delegate = self
            self.webAuthView = webView
            isUsingWebAuth = true
            
            // Get configuration from Info.plist
            let clientId = try self.clientID
            let redirectUrl = try self.redirectURL
            let scopeStrings = try self.scopes
            
            webView.startOAuthFlow(
                clientId: clientId,
                redirectUri: redirectUrl.absoluteString,
                scopes: scopeStrings,
                showDialog: config.showDialog,
                campaign: config.campaign
            )
            
            module?.presentWebAuth(webView)
        }
    } catch {
        module?.onAuthorizationError(error)
    }
  }
  
  private func retryAuthentication() {
    guard !isAuthenticating else { return }
    
    do {
      guard let sessionManager = self.sessionManager else {
        throw SpotifyAuthError.sessionError("Session manager not initialized")
      }
      let scopes = try self.scopes
      let sptScopes = scopes.reduce(into: SPTScope()) { result, scopeString in
          if let scope = stringToScope(scopeString: scopeString) {
              result.insert(scope)
          }
      }
      isAuthenticating = true
      sessionManager.initiateSession(with: sptScopes, options: .default, campaign: nil)
    } catch {
      isAuthenticating = false
      handleError(error, context: "authentication_retry")
    }
  }
  
  // MARK: - SPTSessionManagerDelegate
  
  public func sessionManager(manager: SPTSessionManager, didInitiate session: SPTSession) {
    secureLog("Authentication successful")
    isAuthenticating = false
    if let sessionData = SpotifySessionData(session: session) {
      currentSession = sessionData
    }
  }
  
  public func sessionManager(manager: SPTSessionManager, didFailWith error: Error) {
    secureLog("Authentication failed")
    isAuthenticating = false
    currentSession = nil
    handleError(error, context: "authentication")
  }
  
  public func sessionManager(manager: SPTSessionManager, didRenew session: SPTSession) {
    secureLog("Token renewed successfully")
    if let sessionData = SpotifySessionData(session: session) {
      currentSession = sessionData
    }
  }
  
  public func clearSession() {
    currentSession = nil
    module?.onSignOut()
  }
  
  // MARK: - SpotifyOAuthViewDelegate
  
  func oauthView(_ view: SpotifyOAuthView, didReceiveCode code: String) {
    // Exchange the code for tokens using tokenSwapURL.
    exchangeCodeForToken(code)
    cleanupWebAuth()
  }
  
  func oauthView(_ view: SpotifyOAuthView, didFailWithError error: Error) {
    handleError(error, context: "web_authentication")
    cleanupWebAuth()
  }
  
  func oauthViewDidCancel(_ view: SpotifyOAuthView) {
    module?.onAuthorizationError(SpotifyAuthError.authenticationFailed("User cancelled authentication"))
    cleanupWebAuth()
  }
  
  private func cleanupWebAuth() {
    isUsingWebAuth = false
    webAuthView = nil
    currentConfig = nil
    module?.dismissWebAuth()
  }
  
  /// Exchange an authorization code for tokens.
  private func exchangeCodeForToken(_ code: String) {
    guard let swapURLString = try? self.tokenSwapURL,
          let url = URL(string: swapURLString) else {
      handleError(SpotifyAuthError.invalidConfiguration("Invalid token swap URL"), context: "token_exchange")
      return
    }
    
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    
    let params: [String: String]
    do {
        params = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": try self.redirectURL.absoluteString,
            "client_id": try self.clientID
        ]
    } catch {
        handleError(error, context: "token_exchange")
        return
    }
    
    let bodyString = params.map { "\($0)=\($1)" }.joined(separator: "&")
    request.httpBody = bodyString.data(using: .utf8)
    
    let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
        if let error = error {
            self?.handleError(SpotifyAuthError.networkError(error.localizedDescription), context: "token_exchange")
            return
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            self?.handleError(SpotifyAuthError.networkError("Invalid response type"), context: "token_exchange")
            return
        }
        
        // Check HTTP status code
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMessage: String
            if let data = data, let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorDescription = errorJson["error_description"] as? String {
                errorMessage = errorDescription
            } else {
                errorMessage = "Server returned status code \(httpResponse.statusCode)"
            }
            self?.handleError(SpotifyAuthError.networkError(errorMessage), context: "token_exchange")
            return
        }
        
        guard let data = data else {
            self?.handleError(SpotifyAuthError.tokenError("No data received"), context: "token_exchange")
            return
        }
        
        do {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let json = json,
                  let accessToken = json["access_token"] as? String,
                  let refreshToken = json["refresh_token"] as? String,
                  let expiresIn = json["expires_in"] as? TimeInterval else {
                throw SpotifyAuthError.tokenError("Invalid token response format")
            }
            
            let expirationDate = Date(timeIntervalSinceNow: expiresIn)
            let sessionData = SpotifySessionData(accessToken: accessToken, refreshToken: refreshToken, expirationDate: expirationDate)
            DispatchQueue.main.async {
                self?.currentSession = sessionData
                self?.module?.onAccessTokenObtained(accessToken)
            }
        } catch {
            self?.handleError(error, context: "token_exchange")
        }
    }
    
    task.resume()
  }
  
  // MARK: - Helpers
  
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
    
    if let existingSpotifyError = error as? SpotifyAuthError {
        spotifyError = existingSpotifyError
    } else {
        spotifyError = .authenticationFailed(error.localizedDescription)
    }
    
    secureLog("Error in \(context): \(spotifyError.localizedDescription)")
    
    switch spotifyError.retryStrategy {
    case .none:
        module?.onAuthorizationError(spotifyError)
        cleanupPreviousSession()
    case .retry(let attempts, let delay):
        handleRetry(error: spotifyError, context: context, remainingAttempts: attempts, delay: delay)
    case .exponentialBackoff(let maxAttempts, let initialDelay):
        handleExponentialBackoff(error: spotifyError, context: context, remainingAttempts: maxAttempts, currentDelay: initialDelay)
    }
  }
  
  private func handleRetry(error: SpotifyAuthError, context: String, remainingAttempts: Int, delay: TimeInterval) {
    guard remainingAttempts > 0 else {
      module?.onAuthorizationError(SpotifyAuthError.authenticationFailed("\(error.localizedDescription) (Max retries reached)"))
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
      module?.onAuthorizationError(SpotifyAuthError.authenticationFailed("\(error.localizedDescription) (Max retries reached)"))
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
  
  private func secureLog(_ message: String) {
    print("[SpotifyAuthAuth] \(message)")
  }
  
  deinit {
    cleanupPreviousSession()
  }
}

// MARK: - Helper Extension

extension SPTScope {
  /// Converts an SPTScope value into an array of scope strings.
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
