package expo.modules.spotifyauth

/**
 * Retry strategy for recoverable errors, mirroring the iOS implementation.
 */
sealed class RetryStrategy {
    object None : RetryStrategy()
    data class Retry(val attempts: Int, val delay: Double) : RetryStrategy()
    data class ExponentialBackoff(val maxAttempts: Int, val initialDelay: Double) : RetryStrategy()
}

/**
 * Spotify authentication error hierarchy, mirroring the iOS SpotifyAuthError enum.
 */
sealed class SpotifyAuthException(message: String) : Exception(message) {

    open val isRecoverable: Boolean = false
    open val retryStrategy: RetryStrategy = RetryStrategy.None

    class MissingConfiguration(field: String) :
        SpotifyAuthException("Missing configuration: $field. Please check your app configuration.") {
        override val isRecoverable = false
    }

    class InvalidConfiguration(reason: String) :
        SpotifyAuthException("Invalid configuration: $reason. Please verify your settings.") {
        override val isRecoverable = false
    }

    class AuthenticationFailed(reason: String) :
        SpotifyAuthException("Authentication failed: $reason. Please try again.") {
        override val isRecoverable = false
    }

    class TokenError(reason: String) :
        SpotifyAuthException("Token error: $reason. Please try logging in again.") {
        override val isRecoverable = true
        override val retryStrategy = RetryStrategy.Retry(attempts = 3, delay = 5.0)
    }

    class SessionError(msg: String) :
        SpotifyAuthException("Session error: $msg. Please restart the authentication process.") {
        override val isRecoverable = false
    }

    class NetworkError(reason: String) :
        SpotifyAuthException("Network error: $reason. Please check your internet connection.") {
        override val isRecoverable = true
        override val retryStrategy = RetryStrategy.ExponentialBackoff(maxAttempts = 3, initialDelay = 1.0)
    }

    class Recoverable(msg: String, override val retryStrategy: RetryStrategy) :
        SpotifyAuthException(msg) {
        override val isRecoverable = true
    }

    class UserCancelled :
        SpotifyAuthException("User cancelled the authentication process.") {
        override val isRecoverable = false
    }

    class AuthorizationError(reason: String) :
        SpotifyAuthException("Authorization error: $reason. Please try logging in again.") {
        override val isRecoverable = false
    }

    class InvalidRedirectURL :
        SpotifyAuthException("Invalid redirect URL. Please check your app configuration.") {
        override val isRecoverable = false
    }

    class StateMismatch :
        SpotifyAuthException("State mismatch error. Please try logging in again.") {
        override val isRecoverable = false
    }
}
