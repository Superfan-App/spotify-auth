package expo.modules.spotifyauth

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.spotify.sdk.android.auth.AuthorizationClient
import com.spotify.sdk.android.auth.AuthorizationRequest
import com.spotify.sdk.android.auth.AuthorizationResponse
import expo.modules.kotlin.AppContext
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

/**
 * Core Spotify authentication logic for Android, mirroring the iOS SpotifyAuthAuth class.
 *
 * Supports two auth flows:
 * 1. App-switch via Spotify's AuthorizationClient (when Spotify app is installed)
 * 2. Web auth via AuthorizationClient's WebView fallback (built into the Spotify auth-lib)
 *
 * Token exchange and refresh are handled via the backend token swap/refresh URLs,
 * matching the iOS implementation.
 */
class SpotifyAuthAuth private constructor(private val appContext: AppContext) {

    companion object {
        private const val TAG = "SpotifyAuth"
        private const val REQUEST_CODE = 1337
        private const val ENCRYPTED_PREFS_FILE = "expo_spotify_auth_prefs"
        private const val PREF_REFRESH_TOKEN_KEY = "refresh_token"

        @Volatile
        private var instance: SpotifyAuthAuth? = null

        fun getInstance(appContext: AppContext): SpotifyAuthAuth {
            return instance ?: synchronized(this) {
                instance ?: SpotifyAuthAuth(appContext).also { instance = it }
            }
        }
    }

    /** Weak-ish reference to the module for sending events back to JS. */
    var module: SpotifyAuthModule? = null

    private var isAuthenticating = false
    private var currentSession: SpotifySessionData? = null
        set(value) {
            field = value
            if (value == null) {
                cleanupPreviousSession()
            } else {
                refreshHandler.removeCallbacksAndMessages(null)
                securelyStoreToken(value)
                scheduleTokenRefresh(value)
                retryAttemptsRemaining.clear()
                retryDelays.clear()
            }
        }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val refreshHandler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()

    // Retry tracking
    private val retryAttemptsRemaining = mutableMapOf<String, Int>()
    private val retryDelays = mutableMapOf<String, Double>()

    // region Configuration from Android meta-data / resources

    private fun getMetaData(key: String): String? {
        val context = appContext.reactContext ?: return null
        return try {
            val ai = context.packageManager.getApplicationInfo(
                context.packageName,
                PackageManager.GET_META_DATA
            )
            ai.metaData?.getString(key)
        } catch (e: Exception) {
            null
        }
    }

    private val clientID: String
        get() = getMetaData("SpotifyClientID")
            ?: throw SpotifyAuthException.MissingConfiguration("SpotifyClientID in AndroidManifest meta-data")

    private val redirectURL: String
        get() = getMetaData("SpotifyRedirectURL")
            ?: throw SpotifyAuthException.MissingConfiguration("SpotifyRedirectURL in AndroidManifest meta-data")

    private val tokenSwapURL: String
        get() = getMetaData("SpotifyTokenSwapURL")
            ?: throw SpotifyAuthException.MissingConfiguration("SpotifyTokenSwapURL in AndroidManifest meta-data")

    private val tokenRefreshURL: String
        get() = getMetaData("SpotifyTokenRefreshURL")
            ?: throw SpotifyAuthException.MissingConfiguration("SpotifyTokenRefreshURL in AndroidManifest meta-data")

    private val scopes: List<String>
        get() {
            val scopesStr = getMetaData("SpotifyScopes")
                ?: throw SpotifyAuthException.MissingConfiguration("SpotifyScopes in AndroidManifest meta-data")
            return scopesStr.split(",").map { it.trim() }.filter { it.isNotEmpty() }
        }

    // endregion

    // region Authentication Flow

    /**
     * Initiate the Spotify authorization flow.
     * Uses Spotify's AuthorizationClient which handles both app-switch (when Spotify is installed)
     * and WebView fallback automatically.
     */
    fun initAuth(config: AuthorizeConfig) {
        try {
            val activity = appContext.currentActivity
                ?: throw SpotifyAuthException.SessionError("No activity available")

            val clientId = clientID
            val redirectUri = redirectURL
            val scopeArray = scopes.toTypedArray()

            if (scopeArray.isEmpty()) {
                throw SpotifyAuthException.InvalidConfiguration("No valid scopes found in configuration")
            }

            isAuthenticating = true

            val builder = AuthorizationRequest.Builder(
                clientId,
                AuthorizationResponse.Type.CODE,
                redirectUri
            )
            builder.setScopes(scopeArray)

            if (config.showDialog) {
                builder.setShowDialog(true)
            }

            // Note: The Android Spotify auth-lib doesn't support a 'campaign' parameter
            // on authorization requests (unlike iOS). The campaign param is ignored on Android.

            val request = builder.build()

            // AuthorizationClient.openLoginActivity handles both flows:
            // - If Spotify is installed: app-switch auth
            // - If Spotify is not installed: opens a WebView with Spotify login
            AuthorizationClient.openLoginActivity(activity, REQUEST_CODE, request)
        } catch (e: SpotifyAuthException) {
            isAuthenticating = false
            module?.onAuthorizationError(e)
        } catch (e: Exception) {
            isAuthenticating = false
            module?.onAuthorizationError(
                SpotifyAuthException.AuthenticationFailed(e.message ?: "Unknown error")
            )
        }
    }

    /**
     * Handle the result from Spotify's AuthorizationClient activity.
     * Called by the module's OnActivityResult handler.
     */
    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != REQUEST_CODE) return

        isAuthenticating = false

        val response = AuthorizationClient.getResponse(resultCode, data)

        when (response.type) {
            AuthorizationResponse.Type.CODE -> {
                secureLog("Authorization code received")
                val code = response.code
                if (code != null) {
                    exchangeCodeForToken(code)
                } else {
                    module?.onAuthorizationError(
                        SpotifyAuthException.AuthenticationFailed("No authorization code received")
                    )
                }
            }
            AuthorizationResponse.Type.ERROR -> {
                val errorMsg = response.error ?: "Unknown error"
                secureLog("Authorization error: $errorMsg")
                if (errorMsg.contains("access_denied", ignoreCase = true) ||
                    errorMsg.contains("cancelled", ignoreCase = true)) {
                    module?.onAuthorizationError(SpotifyAuthException.UserCancelled())
                } else {
                    module?.onAuthorizationError(SpotifyAuthException.AuthorizationError(errorMsg))
                }
            }
            AuthorizationResponse.Type.EMPTY -> {
                secureLog("Authorization was cancelled or returned empty")
                module?.onAuthorizationError(SpotifyAuthException.UserCancelled())
            }
            else -> {
                module?.onAuthorizationError(
                    SpotifyAuthException.AuthenticationFailed("Unexpected response type: ${response.type}")
                )
            }
        }
    }

    // endregion

    // region Token Exchange

    /**
     * Exchange an authorization code for access + refresh tokens via the backend token swap URL.
     */
    private fun exchangeCodeForToken(code: String) {
        executor.execute {
            try {
                val swapUrl = tokenSwapURL
                val redirect = redirectURL

                if (!swapUrl.startsWith("https://")) {
                    throw SpotifyAuthException.InvalidConfiguration("Token swap URL must use HTTPS")
                }

                val url = URL(swapUrl)
                val connection = url.openConnection() as HttpURLConnection
                connection.apply {
                    requestMethod = "POST"
                    setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
                    doOutput = true
                    connectTimeout = 15000
                    readTimeout = 15000
                }

                val body = "code=${Uri.encode(code)}&redirect_uri=${Uri.encode(redirect)}"
                OutputStreamWriter(connection.outputStream).use { writer ->
                    writer.write(body)
                    writer.flush()
                }

                val responseCode = connection.responseCode
                if (responseCode !in 200..299) {
                    val errorMessage = extractErrorMessage(connection, responseCode)
                    throw SpotifyAuthException.NetworkError(errorMessage)
                }

                val responseBody = BufferedReader(InputStreamReader(connection.inputStream)).use {
                    it.readText()
                }

                val parsed = parseTokenJSON(responseBody)

                val refreshToken = parsed.refreshToken
                    ?: throw SpotifyAuthException.TokenError("Missing refresh_token in response")

                val expirationTime = System.currentTimeMillis() + (parsed.expiresIn * 1000).toLong()

                val session = SpotifySessionData(
                    accessToken = parsed.accessToken,
                    refreshToken = refreshToken,
                    expirationTime = expirationTime,
                    scope = parsed.scope
                )

                mainHandler.post {
                    currentSession = session
                }

            } catch (e: SpotifyAuthException) {
                handleError(e, "token_exchange")
            } catch (e: Exception) {
                handleError(
                    SpotifyAuthException.NetworkError(e.message ?: "Token exchange failed"),
                    "token_exchange"
                )
            }
        }
    }

    // endregion

    // region Token Refresh

    private fun scheduleTokenRefresh(session: SpotifySessionData) {
        refreshHandler.removeCallbacksAndMessages(null)

        // Refresh 5 minutes (300s) before expiration
        val refreshDelay = session.expirationTime - System.currentTimeMillis() - 300_000L

        if (refreshDelay > 0) {
            refreshHandler.postDelayed({ refreshToken() }, refreshDelay)
        } else {
            refreshToken()
        }
    }

    private fun refreshToken() {
        executor.execute {
            try {
                val session = currentSession
                    ?: throw SpotifyAuthException.SessionError("No session available")

                val refreshUrl = tokenRefreshURL
                if (!refreshUrl.startsWith("https://")) {
                    throw SpotifyAuthException.InvalidConfiguration("Token refresh URL must use HTTPS")
                }

                val url = URL(refreshUrl)
                val connection = url.openConnection() as HttpURLConnection
                connection.apply {
                    requestMethod = "POST"
                    setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
                    doOutput = true
                    connectTimeout = 15000
                    readTimeout = 15000
                }

                val body = "refresh_token=${Uri.encode(session.refreshToken)}"
                OutputStreamWriter(connection.outputStream).use { writer ->
                    writer.write(body)
                    writer.flush()
                }

                val responseCode = connection.responseCode
                if (responseCode !in 200..299) {
                    val errorMessage = extractErrorMessage(connection, responseCode)
                    throw SpotifyAuthException.NetworkError(errorMessage)
                }

                val responseBody = BufferedReader(InputStreamReader(connection.inputStream)).use {
                    it.readText()
                }

                val parsed = parseTokenJSON(responseBody)

                // Keep the existing refresh token since the server typically doesn't send a new one
                val expirationTime = System.currentTimeMillis() + (parsed.expiresIn * 1000).toLong()
                val newSession = SpotifySessionData(
                    accessToken = parsed.accessToken,
                    refreshToken = session.refreshToken,
                    expirationTime = expirationTime,
                    scope = parsed.scope
                )

                mainHandler.post {
                    currentSession = newSession
                }

            } catch (e: SpotifyAuthException) {
                handleError(e, "token_refresh")
            } catch (e: Exception) {
                handleError(
                    SpotifyAuthException.NetworkError(e.message ?: "Token refresh failed"),
                    "token_refresh"
                )
            }
        }
    }

    // endregion

    // region Secure Storage

    private fun getEncryptedPrefs(): android.content.SharedPreferences? {
        val context = appContext.reactContext ?: return null
        return try {
            val masterKey = MasterKey.Builder(context)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            EncryptedSharedPreferences.create(
                context,
                ENCRYPTED_PREFS_FILE,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )
        } catch (e: Exception) {
            Log.e(TAG, "Failed to create encrypted prefs: ${e.message}")
            null
        }
    }

    private fun securelyStoreToken(session: SpotifySessionData) {
        // Send the token back to JS
        val expiresIn = (session.expirationTime - System.currentTimeMillis()) / 1000.0
        module?.onAccessTokenObtained(
            session.accessToken,
            session.refreshToken,
            expiresIn,
            session.scope,
            "Bearer"
        )

        // Store refresh token in encrypted shared preferences
        if (session.refreshToken.isNotEmpty()) {
            try {
                getEncryptedPrefs()?.edit()
                    ?.putString(PREF_REFRESH_TOKEN_KEY, session.refreshToken)
                    ?.apply()
            } catch (e: Exception) {
                Log.e(TAG, "Failed to store refresh token securely: ${e.message}")
            }
        }
    }

    private fun cleanupPreviousSession() {
        refreshHandler.removeCallbacksAndMessages(null)

        try {
            getEncryptedPrefs()?.edit()
                ?.remove(PREF_REFRESH_TOKEN_KEY)
                ?.apply()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to clear previous refresh token: ${e.message}")
        }
    }

    // endregion

    // region Web Auth Cancellation

    /**
     * Cancel an in-progress web auth session.
     * On Android, this clears cookies and notifies JS of cancellation.
     */
    fun cancelWebAuth() {
        val activity = appContext.currentActivity
        if (activity != null) {
            AuthorizationClient.stopLoginActivity(activity, REQUEST_CODE)
        }
        module?.onAuthorizationError(SpotifyAuthException.UserCancelled())
        isAuthenticating = false
    }

    // endregion

    // region Session Management

    fun clearSession() {
        currentSession = null
        module?.onSignOut()
    }

    fun cleanup() {
        refreshHandler.removeCallbacksAndMessages(null)
        executor.shutdown()
        instance = null
    }

    // endregion

    // region Error Handling with Retry

    private fun handleError(error: SpotifyAuthException, context: String) {
        secureLog("Error in $context: ${error.message}")

        when (val strategy = error.retryStrategy) {
            is RetryStrategy.None -> {
                module?.onAuthorizationError(error)
                cleanupPreviousSession()
            }
            is RetryStrategy.Retry -> {
                handleRetry(error, context, strategy.attempts, strategy.delay)
            }
            is RetryStrategy.ExponentialBackoff -> {
                handleExponentialBackoff(error, context, strategy.maxAttempts, strategy.initialDelay)
            }
        }
    }

    private fun handleRetry(error: SpotifyAuthException, context: String, remainingAttempts: Int, delay: Double) {
        if (retryAttemptsRemaining[context] == null) {
            retryAttemptsRemaining[context] = remainingAttempts
            retryDelays[context] = delay
        }

        val remaining = retryAttemptsRemaining[context] ?: 0
        if (remaining <= 0) {
            retryAttemptsRemaining.remove(context)
            retryDelays.remove(context)
            module?.onAuthorizationError(
                SpotifyAuthException.AuthenticationFailed("${error.message} (Max retries reached)")
            )
            cleanupPreviousSession()
            return
        }

        retryAttemptsRemaining[context] = remaining - 1
        secureLog("Retrying $context in $delay seconds. Attempts remaining: ${remaining - 1}")

        mainHandler.postDelayed({
            when (context) {
                "token_refresh" -> refreshToken()
                "authentication" -> {
                    // Retry would require re-initiating auth, which needs user interaction
                    // So just report the error instead
                    retryAttemptsRemaining.remove(context)
                    module?.onAuthorizationError(error)
                }
                else -> retryAttemptsRemaining.remove(context)
            }
        }, (delay * 1000).toLong())
    }

    private fun handleExponentialBackoff(
        error: SpotifyAuthException,
        context: String,
        remainingAttempts: Int,
        currentDelay: Double
    ) {
        if (retryAttemptsRemaining[context] == null) {
            retryAttemptsRemaining[context] = remainingAttempts
            retryDelays[context] = currentDelay
        }

        val remaining = retryAttemptsRemaining[context] ?: 0
        if (remaining <= 0) {
            retryAttemptsRemaining.remove(context)
            retryDelays.remove(context)
            module?.onAuthorizationError(
                SpotifyAuthException.AuthenticationFailed("${error.message} (Max retries reached)")
            )
            cleanupPreviousSession()
            return
        }

        val currentRetryDelay = retryDelays[context] ?: currentDelay
        retryAttemptsRemaining[context] = remaining - 1
        retryDelays[context] = currentRetryDelay * 2 // Exponential backoff
        secureLog("Retrying $context in $currentRetryDelay seconds. Attempts remaining: ${remaining - 1}")

        mainHandler.postDelayed({
            when (context) {
                "token_refresh" -> refreshToken()
                "authentication" -> {
                    retryAttemptsRemaining.remove(context)
                    module?.onAuthorizationError(error)
                }
                else -> retryAttemptsRemaining.remove(context)
            }
        }, (currentRetryDelay * 1000).toLong())
    }

    // endregion

    // region Helpers

    private data class ParsedTokenResponse(
        val accessToken: String,
        val refreshToken: String?,
        val expiresIn: Double,
        val scope: String?
    )

    private fun parseTokenJSON(responseBody: String): ParsedTokenResponse {
        val json = JSONObject(responseBody)

        val accessToken = json.optString("access_token", "")
        if (accessToken.isEmpty()) {
            throw SpotifyAuthException.TokenError("Missing access_token in response")
        }

        val expiresIn = when {
            json.has("expires_in") -> json.getDouble("expires_in")
            else -> throw SpotifyAuthException.TokenError("Invalid or missing expires_in in response")
        }

        val tokenType = json.optString("token_type", "")
        if (tokenType.isEmpty() || !tokenType.equals("bearer", ignoreCase = true)) {
            throw SpotifyAuthException.TokenError("Invalid or missing token_type in response")
        }

        val refreshToken = if (json.has("refresh_token")) json.getString("refresh_token") else null
        val scope = if (json.has("scope")) json.getString("scope") else null

        return ParsedTokenResponse(accessToken, refreshToken, expiresIn, scope)
    }

    private fun extractErrorMessage(connection: HttpURLConnection, statusCode: Int): String {
        return try {
            val errorBody = BufferedReader(InputStreamReader(connection.errorStream)).use {
                it.readText()
            }
            val json = JSONObject(errorBody)
            json.optString("error_description", "Server returned status code $statusCode")
        } catch (e: Exception) {
            "Server returned status code $statusCode"
        }
    }

    private fun secureLog(message: String, sensitive: Boolean = false) {
        if (sensitive) {
            Log.d(TAG, "********")
        } else {
            Log.d(TAG, message)
        }
    }

    // endregion
}

/**
 * Simple session data holder, mirroring the iOS SpotifySessionData struct.
 */
data class SpotifySessionData(
    val accessToken: String,
    val refreshToken: String,
    val expirationTime: Long, // System.currentTimeMillis() based
    val scope: String?
) {
    val isExpired: Boolean
        get() = System.currentTimeMillis() >= expirationTime
}
