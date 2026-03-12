// ios/SpotifyASWebAuthSession.swift

import ExpoModulesCore
import AuthenticationServices

/// A lightweight wrapper around ASWebAuthenticationSession for Spotify OAuth
final class SpotifyASWebAuthSession {
    private var authSession: ASWebAuthenticationSession?
    private var presentationContextProvider: ASWebAuthenticationPresentationContextProviding?
    private var isAuthenticating = false
    
    private func secureLog(_ message: String) {
        NSLog("[SpotifyASWebAuth] \(message)")
    }
    
    func startAuthFlow(
        authUrl: URL,
        redirectScheme: String?,
        preferEphemeral: Bool = true,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard !isAuthenticating else {
            secureLog("Auth already in progress, ignoring duplicate start")
            completion(.failure(SpotifyAuthError.authorizationError("Authentication already in progress")))
            return
        }
        
        isAuthenticating = true
        secureLog("Starting auth flow for URL: \(authUrl.absoluteString)")

        // Create the auth session
        authSession = ASWebAuthenticationSession(
            url: authUrl,
            callbackURLScheme: redirectScheme
        ) { [weak self] callbackURL, error in
            self?.isAuthenticating = false
            
            if let error = error {
                if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                    self?.secureLog("User cancelled auth session")
                    completion(.failure(SpotifyAuthError.userCancelled))
                } else {
                    self?.secureLog("Auth session error: \(error.localizedDescription)")
                    completion(.failure(SpotifyAuthError.networkError(error.localizedDescription)))
                }
                return
            }

            guard let callbackURL = callbackURL else {
                self?.secureLog("Auth session returned no callback URL")
                completion(.failure(SpotifyAuthError.authorizationError("No callback URL received")))
                return
            }

            self?.secureLog("Auth session callback received: \(callbackURL.absoluteString)")
            
            completion(.success(callbackURL))
        }
        
        // Configure the session
        authSession?.prefersEphemeralWebBrowserSession = preferEphemeral
        
        // Set up presentation context
        let provider = PresentationContextProvider()
        presentationContextProvider = provider
        authSession?.presentationContextProvider = provider
        
        // Start the session
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let authSession = self.authSession,
                  authSession.start() else {
                self?.secureLog("Failed to start ASWebAuthenticationSession")
                self?.isAuthenticating = false
                completion(.failure(SpotifyAuthError.authorizationError("Failed to start auth session")))
                return
            }
            self.secureLog("Auth session started successfully")
        }
    }
    
    func cancel() {
        authSession?.cancel()
        isAuthenticating = false
        authSession = nil
        presentationContextProvider = nil
    }
    
    deinit {
        authSession?.cancel()
        authSession = nil
        presentationContextProvider = nil
    }
}

// MARK: - Presentation Context Provider

private class PresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scene = UIApplication.shared.connectedScenes
            .filter { $0.activationState == .foregroundActive }
            .first(where: { $0 is UIWindowScene }) as? UIWindowScene
        
        return scene?.keyWindow ?? ASPresentationAnchor()
    }
}
