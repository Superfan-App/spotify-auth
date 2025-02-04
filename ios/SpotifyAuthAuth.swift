import ExpoModulesCore
import SpotifyiOS

final class SpotifyAuthAuth: NSObject, SPTSessionManagerDelegate {
    weak var module: SpotifyAuthModule?

    static let shared = SpotifyAuthAuth()

    private let clientID: String = Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String ?? ""

    private let scheme: String = Bundle.main.object(forInfoDictionaryKey: "SpotifyScheme") as? String ?? ""

    private let callback: String = Bundle.main.object(forInfoDictionaryKey: "SpotifyCallback") as? String ?? ""

    private let tokenRefreshURL: String = Bundle.main.object(forInfoDictionaryKey: "tokenRefreshURL") as? String ?? ""

    private let tokenSwapURL: String = Bundle.main.object(forInfoDictionaryKey: "tokenSwapURL") as? String ?? ""

    private lazy var requestedScopes: SPTScope = {
        let scopeStrings = Bundle.main.object(forInfoDictionaryKey: "SpotifyScopes") as? [String] ?? []
        var combinedScope: SPTScope = []
        for scopeString in scopeStrings {
            if let scope = stringToScope(scopeString: scopeString) {
                combinedScope.insert(scope)
            }
        }
        return combinedScope
    }()

    lazy var configuration = SPTConfiguration(
        clientID: clientID,
        redirectURL: .init(string: "\(scheme)://\(callback)")!
    )

    lazy var sessionManager: SPTSessionManager = {
        if let tokenSwapURL = URL(string: self.tokenSwapURL),
           let tokenRefreshURL = URL(string: self.tokenRefreshURL)
        {
            self.configuration.tokenSwapURL = tokenSwapURL
            self.configuration.tokenRefreshURL = tokenRefreshURL
        }
        let manager = SPTSessionManager(configuration: self.configuration, delegate: self)
        return manager
    }()

    public func initAuth() {
        sessionManager.initiateSession(with: requestedScopes, options: .default)
    }

    public func sessionManager(manager _: SPTSessionManager, didInitiate session: SPTSession) {
        print("success", session)
        module?.onAccessTokenObtained(session.accessToken)
    }

    public func sessionManager(manager _: SPTSessionManager, didFailWith error: Error) {
        print("fail", error)
        module?.onAuthorizationError(error.localizedDescription)
    }

    public func sessionManager(manager _: SPTSessionManager, didRenew session: SPTSession) {
        print("renewed", session)
        module?.onAccessTokenObtained(session.accessToken)
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
}