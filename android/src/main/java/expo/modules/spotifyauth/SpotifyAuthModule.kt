package expo.modules.spotifyauth

import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import expo.modules.kotlin.records.Field
import expo.modules.kotlin.records.Record

private const val SPOTIFY_AUTH_EVENT_NAME = "onSpotifyAuth"

class AuthorizeConfig : Record {
    @Field
    val showDialog: Boolean = false

    @Field
    val campaign: String? = null
}

class SpotifyAuthModule : Module() {
    private val spotifyAuth by lazy {
        SpotifyAuthAuth.getInstance(appContext)
    }

    override fun definition() = ModuleDefinition {
        Name("SpotifyAuth")

        OnCreate {
            secureLog("SpotifyAuthModule OnCreate called")
            try {
                spotifyAuth.module = this@SpotifyAuthModule
                secureLog("Module initialized and linked to SpotifyAuthAuth")
            } catch (e: Exception) {
                android.util.Log.e("SpotifyAuth", "Failed to initialize module: ${e.message}", e)
            }
        }

        Constants(
            "AuthEventName" to SPOTIFY_AUTH_EVENT_NAME
        )

        Events(SPOTIFY_AUTH_EVENT_NAME)

        OnStartObserving {
            secureLog("Started observing events")
        }

        OnStopObserving {
            secureLog("Stopped observing events")
        }

        AsyncFunction("authorize") { config: AuthorizeConfig ->
            secureLog("Authorization requested")
            try {
                spotifyAuth.initAuth(config)
            } catch (e: Exception) {
                val sanitizedError = sanitizeErrorMessage(e.message ?: "Unknown error")
                secureLog("Auth initialization failed: $sanitizedError")
                throw SpotifyAuthException.AuthenticationFailed(sanitizedError)
            }
        }

        AsyncFunction("dismissAuthSession") {
            spotifyAuth.cancelWebAuth()
        }

        OnActivityResult { _, payload ->
            secureLog("OnActivityResult received in module - requestCode=${payload.requestCode}, resultCode=${payload.resultCode}")
            android.util.Log.d("SpotifyAuth", "=== MODULE ACTIVITY RESULT ===")
            android.util.Log.d("SpotifyAuth", "Request code: ${payload.requestCode}")
            android.util.Log.d("SpotifyAuth", "Result code: ${payload.resultCode}")
            android.util.Log.d("SpotifyAuth", "Has data: ${payload.data != null}")
            if (payload.data != null) {
                android.util.Log.d("SpotifyAuth", "Data scheme: ${payload.data?.scheme}")
                android.util.Log.d("SpotifyAuth", "Data host: ${payload.data?.data?.host}")
                android.util.Log.d("SpotifyAuth", "Data path: ${payload.data?.data?.path}")
            }
            android.util.Log.d("SpotifyAuth", "============================")
            spotifyAuth.handleActivityResult(payload.requestCode, payload.resultCode, payload.data)
        }

        OnDestroy {
            spotifyAuth.cleanup()
        }
    }

    // region Event emitters

    fun onAccessTokenObtained(
        token: String,
        refreshToken: String,
        expiresIn: Double,
        scope: String?,
        tokenType: String
    ) {
        secureLog("Access token obtained", sensitive = true)
        val eventData = mapOf(
            "success" to true,
            "token" to token,
            "refreshToken" to refreshToken,
            "expiresIn" to expiresIn,
            "tokenType" to tokenType,
            "scope" to scope,
            "error" to null
        )
        try {
            sendEvent(SPOTIFY_AUTH_EVENT_NAME, eventData)
            secureLog("Success event sent to JS")
        } catch (e: Exception) {
            android.util.Log.e("SpotifyAuth", "Failed to send success event to JS: ${e.message}", e)
        }
    }

    fun onSignOut() {
        secureLog("User signed out")
        val eventData = mapOf(
            "success" to true,
            "token" to null,
            "refreshToken" to null,
            "expiresIn" to null,
            "tokenType" to null,
            "scope" to null,
            "error" to null
        )
        sendEvent(SPOTIFY_AUTH_EVENT_NAME, eventData)
    }

    fun onAuthorizationError(error: Exception) {
        android.util.Log.d("SpotifyAuth", "onAuthorizationError called with: ${error.javaClass.simpleName}: ${error.message}")

        // Skip sending error events for expected state transitions
        if (error is SpotifyAuthException.SessionError) {
            val msg = error.message ?: ""
            if (msg.contains("authentication process") || msg.contains("token exchange")) {
                secureLog("Auth state transition: $msg")
                return
            }
        }

        val errorData: Map<String, Any?> = when (error) {
            is SpotifyAuthException -> mapSpotifyError(error)
            else -> mapOf(
                "type" to "unknown_error",
                "message" to sanitizeErrorMessage(error.message ?: "Unknown error"),
                "details" to mapOf(
                    "error_code" to "unknown",
                    "recoverable" to false,
                    "error_type" to error.javaClass.simpleName
                )
            )
        }

        android.util.Log.e("SpotifyAuth", "Authorization error: ${errorData["message"] ?: "Unknown error"}")

        val eventData = mapOf(
            "success" to false,
            "token" to null,
            "refreshToken" to null,
            "expiresIn" to null,
            "tokenType" to null,
            "scope" to null,
            "error" to errorData
        )

        try {
            sendEvent(SPOTIFY_AUTH_EVENT_NAME, eventData)
            secureLog("Error event sent to JS successfully")
        } catch (e: Exception) {
            android.util.Log.e("SpotifyAuth", "CRITICAL: Failed to send error event to JS: ${e.message}", e)
        }
    }

    // endregion

    // region Error mapping

    private fun mapSpotifyError(error: SpotifyAuthException): Map<String, Any?> {
        val message = sanitizeErrorMessage(error.message ?: "Unknown error")
        val details = mutableMapOf<String, Any?>(
            "recoverable" to error.isRecoverable
        )

        val (type, errorCode) = classifySpotifyError(error)
        details["error_code"] = errorCode

        when (val strategy = error.retryStrategy) {
            is RetryStrategy.Retry -> {
                details["retry"] = mapOf(
                    "type" to "fixed",
                    "attempts" to strategy.attempts,
                    "delay" to strategy.delay
                )
            }
            is RetryStrategy.ExponentialBackoff -> {
                details["retry"] = mapOf(
                    "type" to "exponential",
                    "max_attempts" to strategy.maxAttempts,
                    "initial_delay" to strategy.initialDelay
                )
            }
            RetryStrategy.None -> {
                details["retry"] = null
            }
        }

        return mapOf(
            "type" to type,
            "message" to message,
            "details" to details
        )
    }

    private fun classifySpotifyError(error: SpotifyAuthException): Pair<String, String> {
        return when (error) {
            is SpotifyAuthException.MissingConfiguration,
            is SpotifyAuthException.InvalidConfiguration -> "configuration_error" to "config_invalid"
            is SpotifyAuthException.AuthenticationFailed -> "authorization_error" to "auth_failed"
            is SpotifyAuthException.TokenError -> "token_error" to "token_invalid"
            is SpotifyAuthException.SessionError -> "session_error" to "session_error"
            is SpotifyAuthException.NetworkError -> "network_error" to "network_failed"
            is SpotifyAuthException.Recoverable -> "recoverable_error" to "recoverable_error"
            is SpotifyAuthException.UserCancelled -> "authorization_error" to "user_cancelled"
            is SpotifyAuthException.AuthorizationError -> "authorization_error" to "auth_error"
            is SpotifyAuthException.InvalidRedirectURL -> "configuration_error" to "invalid_redirect_url"
            is SpotifyAuthException.StateMismatch -> "authorization_error" to "state_mismatch"
        }
    }

    // endregion

    // region Helpers

    private fun sanitizeErrorMessage(message: String): String {
        val sensitivePatterns = listOf(
            "((?i)client[_-]?id=)[^&\\s]+",
            "((?i)access_token=)[^&\\s]+",
            "((?i)refresh_token=)[^&\\s]+",
            "((?i)secret=)[^&\\s]+",
            "((?i)api[_-]?key=)[^&\\s]+"
        )

        var sanitized = message
        for (pattern in sensitivePatterns) {
            sanitized = sanitized.replace(Regex(pattern), "$1[REDACTED]")
        }
        return sanitized
    }

    // endregion
}

private fun secureLog(message: String, sensitive: Boolean = false) {
    val isDebug = try {
        // Access the generated BuildConfig at runtime
        Class.forName("expo.modules.spotifyauth.BuildConfig")
            .getField("DEBUG")
            .getBoolean(null)
    } catch (_: Exception) {
        false
    }

    if (isDebug) {
        if (sensitive) {
            android.util.Log.d("SpotifyAuth", "********")
        } else {
            android.util.Log.d("SpotifyAuth", message)
        }
    } else {
        if (!sensitive) {
            android.util.Log.d("SpotifyAuth", message)
        }
    }
}
