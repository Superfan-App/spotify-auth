// ios/SpotifyAuthAuth.swift

import ExpoModulesCore
import SpotifyiOS
import KeychainAccess

/// Parsed token response fields from the Spotify token endpoint.
private struct ParsedTokenResponse {
  let accessToken: String
  let refreshToken: String?
  let expiresIn: TimeInterval
  let scope: String?
}

/// A lightweight session model to hold token information.
struct SpotifySessionData {
  let accessToken: String
  let refreshToken: String
  let expirationDate: Date
  let scope: String?
  
  var isExpired: Bool {
    return Date() >= expirationDate
  }
  
  init(accessToken: String, refreshToken: String, expirationDate: Date, scope: String?) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expirationDate = expirationDate
    self.scope = scope
  }
  
  /// Initialize from an SPTSession (from app‑switch flow)
  init?(session: SPTSession) {
    // We assume that SPTSession has valid properties.
    self.accessToken = session.accessToken
    self.refreshToken = session.refreshToken
    self.expirationDate = session.expirationDate
    self.scope = session.scope.scopesToStringArray().joined(separator: " ")
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
  case userCancelled
  case authorizationError(String)
  case invalidRedirectURL
  case stateMismatch
  
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
    case .userCancelled:
      return "User cancelled the authentication process."
    case .authorizationError(let reason):
      return "Authorization error: \(reason). Please try logging in again."
    case .invalidRedirectURL:
      return "Invalid redirect URL. Please check your app.json configuration."
    case .stateMismatch:
      return "State mismatch error. Please try logging in again."
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
  /// A weak reference to our module's JS interface.
  weak var module: SpotifyAuthModule?
  
  /// For web‑auth we use ASWebAuthenticationSession
  private var webAuthSession: SpotifyASWebAuthSession?
  private var isUsingWebAuth = false
  
  /// Stores the active configuration from JS.
  private var currentConfig: AuthorizeConfig?
  
  /// Our own session model.
  private var currentSession: SpotifySessionData? {
    didSet {
      // Only clean up keychain if we're clearing the session (not replacing with a new one)
      if currentSession == nil {
        cleanupPreviousSession()
      } else if let session = currentSession {
        // Clear the old refresh timer before scheduling a new one
        refreshTimer?.invalidate()
        securelyStoreToken(session)
        scheduleTokenRefresh(session)
        // Clear retry tracking on successful session
        retryAttemptsRemaining.removeAll()
        retryDelays.removeAll()
      }
    }
  }
  
  /// If authentication is in progress.
  private var isAuthenticating: Bool = false
  
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
    let expiresIn = session.expirationDate.timeIntervalSinceNow
    module?.onAccessTokenObtained(session.accessToken, refreshToken: session.refreshToken, expiresIn: expiresIn, scope: session.scope, tokenType: "Bearer")
    
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
  private func refreshToken() {
    if isUsingWebAuth {
      manualRefreshToken()
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
  private func manualRefreshToken() {
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
    
    var components = URLComponents()
    components.queryItems = [URLQueryItem(name: "refresh_token", value: currentSession.refreshToken)]
    request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
    
    let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      do {
        let responseData = try self?.validateHTTPResponse(data: data, response: response, error: error)
        guard let responseData = responseData else { return }
        let parsed = try Self.parseTokenJSON(from: responseData)
        
        // Keep the existing refresh token since server doesn't send a new one
        let refreshToken = currentSession.refreshToken
        let expirationDate = Date(timeIntervalSinceNow: parsed.expiresIn)
        let newSession = SpotifySessionData(accessToken: parsed.accessToken, refreshToken: refreshToken, expirationDate: expirationDate, scope: parsed.scope)
        
        DispatchQueue.main.async {
          self?.currentSession = newSession
        }
      } catch {
        self?.handleError(error, context: "token_refresh")
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
            // Get configuration from Info.plist before dispatching to main thread
            let clientId = try self.clientID
            let redirectUrl = try self.redirectURL
            let scopeStrings = try self.scopes
            let showDialog = config.showDialog
            let campaign = config.campaign
            
            // Ensure all UI operations happen on main thread
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                self.initWebAuth(clientId: clientId, redirectUrl: redirectUrl, scopes: scopeStrings, showDialog: showDialog, campaign: campaign)
            }
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
  
  // MARK: - Web Auth Cancellation
  
  func cancelWebAuth() {
    webAuthSession?.cancel()
    module?.onAuthorizationError(SpotifyAuthError.userCancelled)
    cleanupWebAuth()
  }
  
  private func cleanupWebAuth() {
    isUsingWebAuth = false
    webAuthSession?.cancel()
    webAuthSession = nil
    currentConfig = nil
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
            "code": code,
            "redirect_uri": try self.redirectURL.absoluteString
        ]
    } catch {
        handleError(error, context: "token_exchange")
        return
    }
    
    var components = URLComponents()
    components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
    // URLComponents.percentEncodedQuery properly encodes the values
    request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
    
    let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
        do {
            let responseData = try self?.validateHTTPResponse(data: data, response: response, error: error)
            guard let responseData = responseData else { return }
            let parsed = try Self.parseTokenJSON(from: responseData)
            
            guard let refreshToken = parsed.refreshToken else {
                throw SpotifyAuthError.tokenError("Missing refresh_token in response")
            }
            
            let expirationDate = Date(timeIntervalSinceNow: parsed.expiresIn)
            let sessionData = SpotifySessionData(accessToken: parsed.accessToken, refreshToken: refreshToken, expirationDate: expirationDate, scope: parsed.scope)
            DispatchQueue.main.async {
                self?.currentSession = sessionData
            }
        } catch {
            self?.handleError(error, context: "token_exchange")
        }
    }
    
    task.resume()
  }
  
  // MARK: - Helpers
  
  /// Validate an HTTP response, returning the response data or throwing on failure.
  private func validateHTTPResponse(data: Data?, response: URLResponse?, error: Error?) throws -> Data {
    if let error = error {
      throw SpotifyAuthError.networkError(error.localizedDescription)
    }
    guard let httpResponse = response as? HTTPURLResponse else {
      throw SpotifyAuthError.networkError("Invalid response type")
    }
    guard (200...299).contains(httpResponse.statusCode) else {
      let errorMessage = Self.extractErrorMessage(from: data, statusCode: httpResponse.statusCode)
      throw SpotifyAuthError.networkError(errorMessage)
    }
    guard let data = data else {
      throw SpotifyAuthError.tokenError("No data received")
    }
    return data
  }
  
  /// Extract an error message from an HTTP error response body, falling back to the status code.
  private static func extractErrorMessage(from data: Data?, statusCode: Int) -> String {
    if let data = data,
       let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let errorDescription = errorJson["error_description"] as? String {
      return errorDescription
    }
    return "Server returned status code \(statusCode)"
  }
  
  /// Parse the `expires_in` field from a token response JSON, accepting both Int and Double.
  private static func parseExpiresIn(from json: [String: Any]) throws -> TimeInterval {
    if let expiresInInt = json["expires_in"] as? Int {
      return TimeInterval(expiresInInt)
    } else if let expiresInDouble = json["expires_in"] as? Double {
      return expiresInDouble
    }
    throw SpotifyAuthError.tokenError("Invalid or missing expires_in in response")
  }
  
  /// Parse and validate a token response JSON, returning the validated fields.
  private static func parseTokenJSON(from data: Data) throws -> ParsedTokenResponse {
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw SpotifyAuthError.tokenError("Invalid JSON response")
    }
    guard let accessToken = json["access_token"] as? String else {
      throw SpotifyAuthError.tokenError("Missing access_token in response")
    }
    let expiresIn = try parseExpiresIn(from: json)
    guard let tokenType = json["token_type"] as? String,
          tokenType.lowercased() == "bearer" else {
      throw SpotifyAuthError.tokenError("Invalid or missing token_type in response")
    }
    let refreshToken = json["refresh_token"] as? String
    let scope = json["scope"] as? String
    return ParsedTokenResponse(accessToken: accessToken, refreshToken: refreshToken, expiresIn: expiresIn, scope: scope)
  }
  
  private func stringToScope(scopeString: String) -> SPTScope? {
    let scopeMapping: [String: SPTScope] = [
      "playlist-read-private": .playlistReadPrivate,
      "playlist-read-collaborative": .playlistReadCollaborative,
      "playlist-modify-public": .playlistModifyPublic,
      "playlist-modify-private": .playlistModifyPrivate,
      "user-follow-read": .userFollowRead,
      "user-follow-modify": .userFollowModify,
      "user-library-read": .userLibraryRead,
      "user-library-modify": .userLibraryModify,
      "user-read-birthdate": .userReadBirthDate,
      "user-read-email": .userReadEmail,
      "user-read-private": .userReadPrivate,
      "user-top-read": .userTopRead,
      "ugc-image-upload": .ugcImageUpload,
      "streaming": .streaming,
      "app-remote-control": .appRemoteControl,
      "user-read-playback-state": .userReadPlaybackState,
      "user-modify-playback-state": .userModifyPlaybackState,
      "user-read-currently-playing": .userReadCurrentlyPlaying,
      "user-read-recently-played": .userReadRecentlyPlayed,
      "openid": .openid
    ]
    return scopeMapping[scopeString]
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
  
  /// Track remaining retry attempts per context to properly decrement across async retries.
  private var retryAttemptsRemaining: [String: Int] = [:]
  private var retryDelays: [String: TimeInterval] = [:]
  
  private func handleRetry(error: SpotifyAuthError, context: String, remainingAttempts: Int, delay: TimeInterval) {
    // Initialize tracking on first call for this context
    if retryAttemptsRemaining[context] == nil {
      retryAttemptsRemaining[context] = remainingAttempts
      retryDelays[context] = delay
    }
    
    guard let remaining = retryAttemptsRemaining[context], remaining > 0 else {
      retryAttemptsRemaining.removeValue(forKey: context)
      retryDelays.removeValue(forKey: context)
      module?.onAuthorizationError(SpotifyAuthError.authenticationFailed("\(error.localizedDescription) (Max retries reached)"))
      cleanupPreviousSession()
      return
    }
    
    retryAttemptsRemaining[context] = remaining - 1
    secureLog("Retrying \(context) in \(delay) seconds. Attempts remaining: \(remaining - 1)")
    
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      switch context {
      case "token_refresh":
        self?.refreshToken()
      case "authentication":
        self?.retryAuthentication()
      default:
        self?.retryAttemptsRemaining.removeValue(forKey: context)
      }
    }
  }
  
  private func handleExponentialBackoff(error: SpotifyAuthError, context: String, remainingAttempts: Int, currentDelay: TimeInterval) {
    // Initialize tracking on first call for this context
    if retryAttemptsRemaining[context] == nil {
      retryAttemptsRemaining[context] = remainingAttempts
      retryDelays[context] = currentDelay
    }
    
    guard let remaining = retryAttemptsRemaining[context], remaining > 0 else {
      retryAttemptsRemaining.removeValue(forKey: context)
      retryDelays.removeValue(forKey: context)
      module?.onAuthorizationError(SpotifyAuthError.authenticationFailed("\(error.localizedDescription) (Max retries reached)"))
      cleanupPreviousSession()
      return
    }
    
    let currentRetryDelay = retryDelays[context] ?? currentDelay
    retryAttemptsRemaining[context] = remaining - 1
    retryDelays[context] = currentRetryDelay * 2  // Exponential backoff
    secureLog("Retrying \(context) in \(currentRetryDelay) seconds. Attempts remaining: \(remaining - 1)")
    
    DispatchQueue.main.asyncAfter(deadline: .now() + currentRetryDelay) { [weak self] in
      switch context {
      case "token_refresh":
        self?.refreshToken()
      case "authentication":
        self?.retryAuthentication()
      default:
        self?.retryAttemptsRemaining.removeValue(forKey: context)
      }
    }
  }
  
  // MARK: - Logging
  
  private func secureLog(_ message: String, sensitive: Bool = false) {
    #if DEBUG
    if sensitive {
      print("[SpotifyAuth] ********")
    } else {
      print("[SpotifyAuth] \(message)")
    }
    #else
    if !sensitive {
      print("[SpotifyAuth] \(message)")
    }
    #endif
  }
  
  deinit {
    cleanupPreviousSession()
  }
  
  // MARK: - URL Handling
  
  /// Handle URL callback for UIApplicationDelegate
  public func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
    // If we're using web auth, let the web view handle it
    if isUsingWebAuth {
      return false
    }
    
    // Forward to session manager for app-switch flow
    if let sessionManager = self.sessionManager {
      let handled = sessionManager.application(app, open: url, options: options)
      if handled {
        secureLog("URL handled by session manager")
      }
      return handled
    }
    
    return false
  }
  
  /// Handle URL callback for UISceneDelegate
  public func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    guard let url = URLContexts.first?.url else {
      return
    }
    
    // If we're using web auth, let the web view handle it
    if isUsingWebAuth {
      return
    }
    
    // Forward to session manager for app-switch flow
    if let sessionManager = self.sessionManager {
      let handled = sessionManager.application(UIApplication.shared, open: url, options: [:])
      if handled {
        secureLog("URL handled by session manager")
      }
    }
  }
  
  private func initWebAuth(clientId: String, redirectUrl: URL, scopes: [String], showDialog: Bool, campaign: String?) {
    guard var urlComponents = URLComponents(string: "https://accounts.spotify.com/authorize") else {
      module?.onAuthorizationError(SpotifyAuthError.invalidRedirectURL)
      return
    }
    
    // Generate state for CSRF protection
    let state = UUID().uuidString
    
    var queryItems = [
      URLQueryItem(name: "client_id", value: clientId),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "redirect_uri", value: redirectUrl.absoluteString),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
      URLQueryItem(name: "show_dialog", value: showDialog ? "true" : "false")
    ]
    
    if let campaign = campaign {
      queryItems.append(URLQueryItem(name: "campaign", value: campaign))
    }
    
    urlComponents.queryItems = queryItems
    
    guard let authUrl = urlComponents.url else {
      module?.onAuthorizationError(SpotifyAuthError.invalidRedirectURL)
      return
    }
    
    // Create and start web auth session
    webAuthSession = SpotifyASWebAuthSession()
    webAuthSession?.startAuthFlow(
      authUrl: authUrl,
      redirectScheme: redirectUrl.scheme,
      preferEphemeral: true
    ) { [weak self] result in
      switch result {
      case .success(let callbackURL):
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: true),
              let queryItems = components.queryItems else {
          self?.module?.onAuthorizationError(SpotifyAuthError.invalidRedirectURL)
          return
        }
        
        // Verify state parameter to prevent CSRF attacks
        guard let returnedState = queryItems.first(where: { $0.name == "state" })?.value,
              returnedState == state else {
          self?.module?.onAuthorizationError(SpotifyAuthError.stateMismatch)
          return
        }
        
        if let error = queryItems.first(where: { $0.name == "error" })?.value {
          if error == "access_denied" {
            self?.module?.onAuthorizationError(SpotifyAuthError.userCancelled)
          } else {
            self?.module?.onAuthorizationError(SpotifyAuthError.authorizationError(error))
          }
        } else if let code = queryItems.first(where: { $0.name == "code" })?.value {
          self?.exchangeCodeForToken(code)
        }
        
      case .failure(let error):
        self?.module?.onAuthorizationError(error)
      }
      
      self?.cleanupWebAuth()
    }
  }
}

// MARK: - Helper Extension

extension SPTScope {
  /// Converts an SPTScope value into an array of scope strings.
  func scopesToStringArray() -> [String] {
    let scopeMapping: [(SPTScope, String)] = [
      (.playlistReadPrivate, "playlist-read-private"),
      (.playlistReadCollaborative, "playlist-read-collaborative"),
      (.playlistModifyPublic, "playlist-modify-public"),
      (.playlistModifyPrivate, "playlist-modify-private"),
      (.userFollowRead, "user-follow-read"),
      (.userFollowModify, "user-follow-modify"),
      (.userLibraryRead, "user-library-read"),
      (.userLibraryModify, "user-library-modify"),
      (.userReadBirthDate, "user-read-birthdate"),
      (.userReadEmail, "user-read-email"),
      (.userReadPrivate, "user-read-private"),
      (.userTopRead, "user-top-read"),
      (.ugcImageUpload, "ugc-image-upload"),
      (.streaming, "streaming"),
      (.appRemoteControl, "app-remote-control"),
      (.userReadPlaybackState, "user-read-playback-state"),
      (.userModifyPlaybackState, "user-modify-playback-state"),
      (.userReadCurrentlyPlaying, "user-read-currently-playing"),
      (.userReadRecentlyPlayed, "user-read-recently-played"),
      (.openid, "openid")
    ]

    return scopeMapping.filter { contains($0.0) }.map { $0.1 }
  }
}
