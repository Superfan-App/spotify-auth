import ExpoModulesCore
import WebKit

protocol SpotifyOAuthViewDelegate: AnyObject {
    func oauthView(_ view: SpotifyOAuthView, didReceiveCode code: String)
    func oauthView(_ view: SpotifyOAuthView, didFailWithError error: Error)
    func oauthViewDidCancel(_ view: SpotifyOAuthView)
}

enum SpotifyOAuthError: Error {
    case invalidRedirectURL
    case stateMismatch
    case timeout
    case userCancelled
    case networkError(Error)
    case authorizationError(String)
    
    var localizedDescription: String {
        switch self {
        case .invalidRedirectURL:
            return "Invalid redirect URL"
        case .stateMismatch:
            return "State mismatch - possible CSRF attack"
        case .timeout:
            return "Authentication timed out"
        case .userCancelled:
            return "User cancelled authentication"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .authorizationError(let message):
            return "Authorization error: \(message)"
        }
    }
}

// This view will be used as a native component for web-based OAuth when Spotify app isn't installed
class SpotifyOAuthView: ExpoView {
    weak var delegate: SpotifyOAuthViewDelegate?
    private var webView: WKWebView!
    private let state: String
    private var isAuthenticating = false
    private var expectedRedirectScheme: String?
    private var authTimeout: Timer?
    private static let AUTH_TIMEOUT_INTERVAL: TimeInterval = 300 // 5 minutes
    
    required init(appContext: AppContext? = nil) {
        // Generate a random state string for CSRF protection
        self.state = UUID().uuidString
        super.init(appContext: appContext)
        secureLog("Initializing SpotifyOAuthView with state: \(String(state.prefix(8)))...")
        setupWebView()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupWebView() {
        // Create a configuration that prevents data persistence
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        
        // Ensure cookies and data are not persisted
        let dataStore = WKWebsiteDataStore.nonPersistent()
        config.websiteDataStore = dataStore
        
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = "SpotifyAuth-iOS/1.0" // Custom UA to identify our app
        
        // Add loading indicator
        let activityIndicator = UIActivityIndicatorView(style: .medium)
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.hidesWhenStopped = true
        
        addSubview(webView)
        addSubview(activityIndicator)
        
        // Setup constraints
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            
            activityIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        
        // Start observing loading state
        webView.addObserver(self, forKeyPath: #keyPath(WKWebView.isLoading), options: .new, context: nil)
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == #keyPath(WKWebView.isLoading) {
            if let activityIndicator = subviews.first(where: { $0 is UIActivityIndicatorView }) as? UIActivityIndicatorView {
                webView.isLoading ? activityIndicator.startAnimating() : activityIndicator.stopAnimating()
            }
        }
    }
    
    func startOAuthFlow(clientId: String, redirectUri: String, scopes: [String]) {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        
        // Extract and store the redirect scheme
        guard let url = URL(string: redirectUri),
              let scheme = url.scheme else {
            delegate?.oauthView(self, didFailWithError: SpotifyOAuthError.invalidRedirectURL)
            return
        }
        expectedRedirectScheme = scheme
        
        // Start auth timeout timer
        startAuthTimeout()
        
        // Clear any existing cookies/data to ensure a fresh login
        WKWebsiteDataStore.default().removeData(
            ofTypes: [WKWebsiteDataTypeCookies, WKWebsiteDataTypeSessionStorage],
            modifiedSince: Date(timeIntervalSince1970: 0)
        ) { [weak self] in
            self?.initiateAuthRequest(clientId: clientId, redirectUri: redirectUri, scopes: scopes)
        }
    }
    
    private func startAuthTimeout() {
        authTimeout?.invalidate()
        authTimeout = Timer.scheduledTimer(withTimeInterval: Self.AUTH_TIMEOUT_INTERVAL, repeats: false) { [weak self] _ in
            self?.handleTimeout()
        }
    }
    
    private func handleTimeout() {
        delegate?.oauthView(self, didFailWithError: SpotifyOAuthError.timeout)
        cleanup()
    }
    
    private func cleanup() {
        secureLog("Cleaning up authentication session")
        isAuthenticating = false
        authTimeout?.invalidate()
        authTimeout = nil
        expectedRedirectScheme = nil
        
        // Clear web view data
        WKWebsiteDataStore.default().removeData(
            ofTypes: [WKWebsiteDataTypeCookies, WKWebsiteDataTypeSessionStorage],
            modifiedSince: Date(timeIntervalSince1970: 0)
        ) { }
    }
    
    private func initiateAuthRequest(clientId: String, redirectUri: String, scopes: [String]) {
        guard var urlComponents = URLComponents(string: "https://accounts.spotify.com/authorize") else {
            isAuthenticating = false
            delegate?.oauthView(self, didFailWithError: SpotifyOAuthError.invalidRedirectURL)
            return
        }
        
        urlComponents.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "show_dialog", value: "true")
        ]
        
        guard let url = urlComponents.url else {
            isAuthenticating = false
            delegate?.oauthView(self, didFailWithError: SpotifyOAuthError.invalidRedirectURL)
            return
        }
        
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        webView.load(request)
    }
    
    deinit {
        webView.removeObserver(self, forKeyPath: #keyPath(WKWebView.isLoading))
        authTimeout?.invalidate()
    }
}

extension SpotifyOAuthView: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        
        // Check if the URL matches our redirect URI scheme
        if let expectedScheme = expectedRedirectScheme,
           url.scheme == expectedScheme {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
                  let queryItems = components.queryItems else {
                decisionHandler(.cancel)
                return
            }
            
            // Verify state parameter to prevent CSRF attacks
            guard let returnedState = queryItems.first(where: { $0.name == "state" })?.value,
                  returnedState == state else {
                delegate?.oauthView(self, didFailWithError: SpotifyOAuthError.stateMismatch)
                decisionHandler(.cancel)
                cleanup()
                return
            }
            
            cleanup()
            
            if let error = queryItems.first(where: { $0.name == "error" })?.value {
                if error == "access_denied" {
                    delegate?.oauthView(self, didFailWithError: SpotifyOAuthError.userCancelled)
                } else {
                    delegate?.oauthView(self, didFailWithError: SpotifyOAuthError.authorizationError(error))
                }
            } else if let code = queryItems.first(where: { $0.name == "code" })?.value {
                delegate?.oauthView(self, didReceiveCode: code)
            }
            
            decisionHandler(.cancel)
            return
        }
        
        // Only allow navigation to Spotify domains and our redirect URI
        let allowedDomains = ["accounts.spotify.com", "spotify.com"]
        if let host = url.host,
           allowedDomains.contains(where: { host.hasSuffix($0) }) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }
    
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        delegate?.oauthView(self, didFailWithError: SpotifyOAuthError.networkError(error))
        cleanup()
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        delegate?.oauthView(self, didFailWithError: SpotifyOAuthError.networkError(error))
        cleanup()
    }
    
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Ensure proper SSL/TLS handling
        if let serverTrust = challenge.protectionSpace.serverTrust {
            let credential = URLCredential(trust: serverTrust)
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
