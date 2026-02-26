package expo.modules.spotifyauth

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import expo.modules.kotlin.AppContext
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

/**
 * Core Spotify authentication logic for Android.
 *
 * Opens the Spotify OAuth URL directly in the system browser via Intent.ACTION_VIEW.
 * This avoids using SpotifyAuthorizationActivity (openLoginInBrowser), which conflicts
 * with MainActivity's singleTask launchMode on physical devices: the singleTask mode
 * causes the redirect intent to be routed to MainActivity before SpotifyAuthorizationActivity
 * can call setResult(), resulting in a RESULT_CANCELED that drops the real auth code.
 *
 * By opening the browser directly, the redirect arrives cleanly via onNewIntent on
 * MainActivity, which is handled by handleNewIntent(). This is the same path that
 * works on the emulator.
 *
 * Token exchange and refresh are handled via the backend token swap/refresh URLs,
 * matching the iOS implementation.
 */
class SpotifyAuthAuth private constructor(private val appContext: AppContext) {

    companion object {
        private const val TAG = "SpotifyAuth"
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
        set(value) {
            field = value
            if (value != null) {
                secureLog("Module reference set successfully")
            } else {
                Log.w(TAG, "Module reference set to null")
            }
        }

    private var isAuthenticating = false
    private var authTimeoutHandler: Runnable? = null
    private val AUTH_TIMEOUT_MS = 60_000L // 60 seconds timeout
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
            Log.e(TAG, "Failed to get meta-data for key $key: ${e.message}")
            null
        }
    }

    private fun isSpotifyInstalled(): Boolean {
        val context = appContext.reactContext ?: return false
        return try {
            val packageInfo = context.packageManager.getPackageInfo("com.spotify.music", 0)
            Log.d(TAG, "Spotify app detected: com.spotify.music (version: ${packageInfo.versionName})")
            true
        } catch (e: PackageManager.NameNotFoundException) {
            Log.d(TAG, "Spotify app NOT detected: ${e.message}")
            Log.d(TAG, "If Spotify IS installed, this may be a package visibility issue (Android 11+)")
            Log.d(TAG, "Ensure <queries><package android:name=\"com.spotify.music\"/></queries> is in merged manifest")
            false
        } catch (e: Exception) {
            Log.e(TAG, "Error checking for Spotify app: ${e.message}", e)
            false
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

    /**
     * Verify the app configuration and log any potential issues.
     * Helps diagnose setup problems.
     */
    private fun verifyConfiguration() {
        try {
            val context = appContext.reactContext
            if (context == null) {
                Log.e(TAG, "React context is null - app may not be fully initialized")
                return
            }

            // Check meta-data configuration
            val configKeys = listOf(
                "SpotifyClientID",
                "SpotifyRedirectURL",
                "SpotifyScopes",
                "SpotifyTokenSwapURL",
                "SpotifyTokenRefreshURL"
            )

            var allConfigured = true
            for (key in configKeys) {
                val value = getMetaData(key)
                if (value.isNullOrEmpty()) {
                    Log.e(TAG, "Missing or empty configuration: $key")
                    allConfigured = false
                } else {
                    Log.d(TAG, "Configuration $key: ${if (key.contains("URL") || key.contains("ID")) value.take(20) + "..." else value}")
                }
            }

            if (allConfigured) {
                Log.d(TAG, "All required configuration values are present")
            } else {
                Log.e(TAG, "Some configuration values are missing - auth will likely fail")
            }

            // Check if Spotify app is installed
            val spotifyInstalled = isSpotifyInstalled()
            Log.d(TAG, "Spotify app installed: $spotifyInstalled")

        } catch (e: Exception) {
            Log.e(TAG, "Error during configuration verification: ${e.message}", e)
        }
    }

    // endregion

    // region Authentication Flow

    /**
     * Initiate the Spotify authorization flow via the system browser.
     *
     * Opens the Spotify OAuth URL directly with Intent.ACTION_VIEW instead of using
     * AuthorizationClient.openLoginInBrowser(), which internally starts
     * SpotifyAuthorizationActivity via startActivityForResult. That approach breaks
     * on physical devices when MainActivity has launchMode="singleTask": the redirect
     * intent is routed to MainActivity (clearing SpotifyAuthorizationActivity from the
     * stack before setResult is called), so onActivityResult gets RESULT_CANCELED and
     * the real auth code arrives via onNewIntent after isAuthenticating has been reset.
     *
     * Opening the browser directly skips SpotifyAuthorizationActivity entirely.
     * The auth result is always delivered via onNewIntent → handleNewIntent().
     */
    fun initAuth(config: AuthorizeConfig) {
        secureLog("initAuth called with showDialog=${config.showDialog}")

        // Verify configuration on first auth attempt
        verifyConfiguration()

        // Cancel any existing timeout
        authTimeoutHandler?.let { mainHandler.removeCallbacks(it) }

        try {
            if (module == null) {
                Log.e(TAG, "CRITICAL: Module reference is null when initAuth called")
                throw SpotifyAuthException.SessionError("Module not properly initialized")
            }

            val activity = appContext.currentActivity
            if (activity == null) {
                Log.e(TAG, "CRITICAL: No current activity available for auth")
                throw SpotifyAuthException.SessionError("No activity available")
            }

            secureLog("Current activity: ${activity.javaClass.simpleName}")

            val clientId = clientID
            val redirectUri = redirectURL
            val scopeList = scopes

            secureLog("Configuration - ClientID: ${clientId.take(8)}..., RedirectURI: $redirectUri, Scopes: ${scopeList.size}")

            if (scopeList.isEmpty()) {
                Log.e(TAG, "No valid scopes found in configuration")
                throw SpotifyAuthException.InvalidConfiguration("No valid scopes found in configuration")
            }

            if (isAuthenticating) {
                Log.w(TAG, "Auth already in progress, ignoring duplicate request")
                return
            }

            isAuthenticating = true
            secureLog("Setting isAuthenticating to true")

            // Build the standard Spotify OAuth authorization URL.
            val authUri = Uri.Builder()
                .scheme("https")
                .authority("accounts.spotify.com")
                .path("/authorize")
                .appendQueryParameter("client_id", clientId)
                .appendQueryParameter("response_type", "code")
                .appendQueryParameter("redirect_uri", redirectUri)
                .appendQueryParameter("scope", scopeList.joinToString(" "))
                .apply { if (config.showDialog) appendQueryParameter("show_dialog", "true") }
                .build()

            Log.d(TAG, "=== SPOTIFY AUTH DEBUG ===")
            Log.d(TAG, "Auth flow: direct browser (Intent.ACTION_VIEW)")
            Log.d(TAG, "Client ID: ${clientId.take(10)}...")
            Log.d(TAG, "Redirect URI: $redirectUri")
            Log.d(TAG, "Scopes: ${scopeList.joinToString(",")}")
            Log.d(TAG, "Package name: ${appContext.reactContext?.packageName}")
            Log.d(TAG, "Activity: ${activity.javaClass.name}")
            Log.d(TAG, "========================")

            // Set a timeout to detect if the auth flow doesn't complete
            authTimeoutHandler = Runnable {
                if (isAuthenticating) {
                    Log.e(TAG, "Auth timeout - no response received after ${AUTH_TIMEOUT_MS}ms")
                    isAuthenticating = false
                    module?.onAuthorizationError(
                        SpotifyAuthException.AuthenticationFailed("Authorization timed out. Please try again.")
                    )
                }
            }
            mainHandler.postDelayed(authTimeoutHandler!!, AUTH_TIMEOUT_MS)

            try {
                activity.startActivity(Intent(Intent.ACTION_VIEW, authUri))
                secureLog("Browser opened for Spotify auth")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to open browser: ${e.message}", e)
                throw SpotifyAuthException.AuthenticationFailed("Failed to open browser: ${e.message}")
            }

        } catch (e: SpotifyAuthException) {
            Log.e(TAG, "Auth initialization failed (SpotifyAuthException): ${e.message}")
            isAuthenticating = false
            authTimeoutHandler?.let { mainHandler.removeCallbacks(it) }
            module?.onAuthorizationError(e) ?: Log.e(TAG, "Cannot send error - module is null")
        } catch (e: Exception) {
            Log.e(TAG, "Auth initialization failed (Exception): ${e.message}", e)
            isAuthenticating = false
            authTimeoutHandler?.let { mainHandler.removeCallbacks(it) }
            val error = SpotifyAuthException.AuthenticationFailed(e.message ?: "Unknown error")
            module?.onAuthorizationError(error) ?: Log.e(TAG, "Cannot send error - module is null")
        }
    }

    /**
     * Handle the Spotify auth callback delivered via onNewIntent.
     *
     * When the browser redirects to superfan://callback?code=XXX, Android routes the
     * intent to MainActivity (via the intent filter in AndroidManifest), which calls
     * onNewIntent. This method parses the redirect URI directly to extract the auth code.
     */
    fun handleNewIntent(intent: Intent) {
        Log.d(TAG, "handleNewIntent called - action=${intent.action}, data=${intent.data}")

        // Only process intents whose data URI matches our Spotify redirect URI (scheme + host).
        // This guards against push notifications, other deep links, or navigation events
        // arriving while isAuthenticating=true accidentally cancelling the auth flow.
        val intentData = intent.data
        if (intentData != null) {
            try {
                val configuredUri = Uri.parse(redirectURL)
                if (intentData.scheme != configuredUri.scheme || intentData.host != configuredUri.host) {
                    Log.d(TAG, "Ignoring new intent - URI doesn't match redirect (got scheme=${intentData.scheme}, host=${intentData.host})")
                    return
                }
            } catch (e: SpotifyAuthException.MissingConfiguration) {
                Log.w(TAG, "Cannot verify redirect URI in handleNewIntent: ${e.message}")
                // Proceed anyway
            }
        }

        if (!isAuthenticating) {
            Log.d(TAG, "Ignoring new intent - not currently authenticating")
            return
        }

        // Cancel the timeout
        authTimeoutHandler?.let {
            mainHandler.removeCallbacks(it)
            secureLog("Auth timeout cancelled")
        }

        isAuthenticating = false
        secureLog("Setting isAuthenticating to false")

        if (module == null) {
            Log.e(TAG, "CRITICAL: Module is null in handleNewIntent - cannot send events to JS")
            return
        }

        val data = intent.data
        if (data == null) {
            Log.e(TAG, "Redirect intent has no data URI")
            module?.onAuthorizationError(SpotifyAuthException.AuthenticationFailed("No redirect data received"))
            return
        }

        val code = data.getQueryParameter("code")
        val error = data.getQueryParameter("error")

        when {
            code != null -> {
                secureLog("Authorization code received")
                exchangeCodeForToken(code)
            }
            error != null -> {
                Log.e(TAG, "Spotify authorization error in redirect: $error")
                if (error == "access_denied") {
                    module?.onAuthorizationError(SpotifyAuthException.UserCancelled())
                } else {
                    module?.onAuthorizationError(SpotifyAuthException.AuthorizationError(error))
                }
            }
            else -> {
                Log.w(TAG, "Redirect URI has no code or error parameter - user likely cancelled")
                module?.onAuthorizationError(SpotifyAuthException.UserCancelled())
            }
        }
    }

    // endregion

    // region Token Exchange

    /**
     * Exchange an authorization code for access + refresh tokens via the backend token swap URL.
     */
    private fun exchangeCodeForToken(code: String) {
        secureLog("Starting token exchange process")

        if (module == null) {
            Log.e(TAG, "CRITICAL: Module is null in exchangeCodeForToken")
            return
        }

        executor.execute {
            try {
                val swapUrl = tokenSwapURL
                val redirect = redirectURL

                Log.d(TAG, "Token swap URL: ${swapUrl.take(30)}...")
                Log.d(TAG, "Redirect URL: $redirect")

                if (!swapUrl.startsWith("https://")) {
                    Log.e(TAG, "Token swap URL does not use HTTPS: $swapUrl")
                    throw SpotifyAuthException.InvalidConfiguration("Token swap URL must use HTTPS")
                }

                val url = URL(swapUrl)
                Log.d(TAG, "Opening connection to token swap URL")

                val connection = url.openConnection() as HttpURLConnection
                connection.apply {
                    requestMethod = "POST"
                    setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
                    doOutput = true
                    connectTimeout = 15000
                    readTimeout = 15000
                }

                val body = "code=${Uri.encode(code)}&redirect_uri=${Uri.encode(redirect)}"
                Log.d(TAG, "Sending token exchange request (code length: ${code.length})")

                OutputStreamWriter(connection.outputStream).use { writer ->
                    writer.write(body)
                    writer.flush()
                }

                val responseCode = connection.responseCode
                Log.d(TAG, "Token exchange response code: $responseCode")

                if (responseCode !in 200..299) {
                    val errorMessage = extractErrorMessage(connection, responseCode)
                    Log.e(TAG, "Token exchange failed with status $responseCode: $errorMessage")
                    throw SpotifyAuthException.NetworkError(errorMessage)
                }

                val responseBody = BufferedReader(InputStreamReader(connection.inputStream)).use {
                    it.readText()
                }

                Log.d(TAG, "Token exchange response received (body length: ${responseBody.length})")

                val parsed = parseTokenJSON(responseBody)

                val refreshToken = parsed.refreshToken
                    ?: throw SpotifyAuthException.TokenError("Missing refresh_token in response")

                val expirationTime = System.currentTimeMillis() + (parsed.expiresIn * 1000).toLong()

                Log.d(TAG, "Token exchange successful - expires in ${parsed.expiresIn} seconds")

                val session = SpotifySessionData(
                    accessToken = parsed.accessToken,
                    refreshToken = refreshToken,
                    expirationTime = expirationTime,
                    scope = parsed.scope
                )

                mainHandler.post {
                    secureLog("Setting currentSession and sending success event to JS")
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
        secureLog("Storing token and sending to JS")

        if (module == null) {
            Log.e(TAG, "CRITICAL: Module is null in securelyStoreToken - cannot send token to JS")
            return
        }

        // Send the token back to JS
        val expiresIn = (session.expirationTime - System.currentTimeMillis()) / 1000.0
        Log.d(TAG, "Sending access token to JS (expires in ${expiresIn}s)")

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
                Log.d(TAG, "Refresh token stored securely")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to store refresh token securely: ${e.message}", e)
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
     * Cancel an in-progress auth session.
     * For browser-based auth the system browser cannot be closed programmatically,
     * so this clears internal state and notifies JS of cancellation.
     */
    fun cancelWebAuth() {
        authTimeoutHandler?.let { mainHandler.removeCallbacks(it) }
        isAuthenticating = false
        module?.onAuthorizationError(SpotifyAuthException.UserCancelled())
    }

    // endregion

    // region Session Management

    fun clearSession() {
        currentSession = null
        module?.onSignOut()
    }

    fun cleanup() {
        secureLog("Cleaning up SpotifyAuthAuth instance")
        authTimeoutHandler?.let { mainHandler.removeCallbacks(it) }
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
