package expo.modules.spotifyauth

import android.app.Activity
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
 * Uses browser-based auth via Spotify's AuthorizationClient.openLoginInBrowser().
 * On Android, app-switch is disabled regardless of whether the Spotify app is installed.
 * Auth results are delivered via onNewIntent (handled by handleNewIntent()).
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
     * On Android, app-switch is always bypassed. The auth result is delivered
     * via onNewIntent, handled by handleNewIntent().
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
            val scopeArray = scopes.toTypedArray()

            secureLog("Configuration - ClientID: ${clientId.take(8)}..., RedirectURI: $redirectUri, Scopes: ${scopeArray.size}")

            if (scopeArray.isEmpty()) {
                Log.e(TAG, "No valid scopes found in configuration")
                throw SpotifyAuthException.InvalidConfiguration("No valid scopes found in configuration")
            }

            if (isAuthenticating) {
                Log.w(TAG, "Auth already in progress, ignoring duplicate request")
                return
            }

            isAuthenticating = true
            secureLog("Setting isAuthenticating to true")

            val builder = AuthorizationRequest.Builder(
                clientId,
                AuthorizationResponse.Type.CODE,
                redirectUri
            )
            builder.setScopes(scopeArray)

            if (config.showDialog) {
                builder.setShowDialog(true)
                secureLog("Force-showing login dialog")
            }

            // Note: The Android Spotify auth-lib doesn't support a 'campaign' parameter
            // on authorization requests (unlike iOS). The campaign param is ignored on Android.

            val request = builder.build()

            secureLog("Opening Spotify authorization in browser")

            // === SPOTIFY AUTH DEBUG ===
            Log.d(TAG, "=== SPOTIFY AUTH DEBUG ===")
            Log.d(TAG, "Auth flow type: BROWSER (app-switch disabled on Android)")
            Log.d(TAG, "Client ID: ${clientId.take(10)}...")
            Log.d(TAG, "Redirect URI: $redirectUri")
            Log.d(TAG, "Response Type: CODE")
            Log.d(TAG, "Scopes: ${scopeArray.joinToString(",")}")
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
                // Use browser-based auth on Android (bypasses Spotify app-switch).
                // The auth result is delivered via onNewIntent, handled by handleNewIntent().
                AuthorizationClient.openLoginInBrowser(activity, request)
                secureLog("AuthorizationClient.openLoginInBrowser called successfully")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to open browser authorization: ${e.message}", e)
                throw SpotifyAuthException.AuthenticationFailed("Failed to open Spotify authorization: ${e.message}")
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
     * Handle the result from Spotify's AuthorizationClient activity.
     * Called by the module's OnActivityResult handler.
     */
    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        Log.d(TAG, "handleActivityResult called - requestCode=$requestCode, resultCode=$resultCode, hasData=${data != null}")

        // === ENHANCED DEBUG LOGGING FOR ACTIVITY RESULT ===
        if (data != null) {
            Log.d(TAG, "Intent data URI: ${data.data}")
            Log.d(TAG, "Intent action: ${data.action}")
            Log.d(TAG, "Intent extras keys: ${data.extras?.keySet()?.joinToString() ?: "none"}")
            data.extras?.let { extras ->
                for (key in extras.keySet()) {
                    val value = extras.get(key)
                    if (key.contains("token", ignoreCase = true) ||
                        key.contains("code", ignoreCase = true) ||
                        key.contains("secret", ignoreCase = true)) {
                        Log.d(TAG, "  $key: [REDACTED]")
                    } else {
                        Log.d(TAG, "  $key: $value")
                    }
                }
            }
        } else {
            Log.w(TAG, "Intent data is NULL - callback may not have fired correctly")
            Log.w(TAG, "This often indicates an intent filter configuration issue")
        }

        if (requestCode != REQUEST_CODE) {
            Log.d(TAG, "Ignoring activity result - wrong request code (expected $REQUEST_CODE, got $requestCode)")
            return
        }

        // Cancel the timeout
        authTimeoutHandler?.let {
            mainHandler.removeCallbacks(it)
            secureLog("Auth timeout cancelled")
        }

        if (!isAuthenticating) {
            Log.w(TAG, "Received activity result but isAuthenticating was false")
        }

        isAuthenticating = false
        secureLog("Setting isAuthenticating to false")

        if (module == null) {
            Log.e(TAG, "CRITICAL: Module is null in handleActivityResult - cannot send events to JS")
            return
        }

        try {
            val response = AuthorizationClient.getResponse(resultCode, data)
            Log.d(TAG, "Spotify response type: ${response.type}")

            when (response.type) {
                AuthorizationResponse.Type.CODE -> {
                    val code = response.code
                    secureLog("Authorization code received, length=${code?.length ?: 0}")
                    if (code != null) {
                        exchangeCodeForToken(code)
                    } else {
                        Log.e(TAG, "Authorization code was null despite CODE response type")
                        module?.onAuthorizationError(
                            SpotifyAuthException.AuthenticationFailed("No authorization code received")
                        )
                    }
                }
                AuthorizationResponse.Type.ERROR -> {
                    val errorMsg = response.error ?: "Unknown error"
                    Log.e(TAG, "Spotify authorization error: $errorMsg")
                    if (errorMsg.contains("access_denied", ignoreCase = true) ||
                        errorMsg.contains("cancelled", ignoreCase = true)) {
                        module?.onAuthorizationError(SpotifyAuthException.UserCancelled())
                    } else {
                        module?.onAuthorizationError(SpotifyAuthException.AuthorizationError(errorMsg))
                    }
                }
                AuthorizationResponse.Type.EMPTY -> {
                    val spotifyInstalled = isSpotifyInstalled()
                    if (spotifyInstalled) {
                        Log.e(TAG, "")
                        Log.e(TAG, "╔══════════════════════════════════════════════════════════════╗")
                        Log.e(TAG, "║  SPOTIFY APP-SWITCH AUTH: EMPTY RESPONSE                     ║")
                        Log.e(TAG, "╠══════════════════════════════════════════════════════════════╣")
                        Log.e(TAG, "║  Spotify is installed but auth returned empty immediately.   ║")
                        Log.e(TAG, "║  The auth dialog flashed and dismissed without going to      ║")
                        Log.e(TAG, "║  Spotify. Common client-side causes:                         ║")
                        Log.e(TAG, "║                                                              ║")
                        Log.e(TAG, "║  1. MainActivity launchMode is singleTask (most likely).     ║")
                        Log.e(TAG, "║     Change to singleTop in your AndroidManifest.xml.         ║")
                        Log.e(TAG, "║                                                              ║")
                        Log.e(TAG, "║  2. Redirect URI '${redirectURL.take(30)}...' not registered  ║")
                        Log.e(TAG, "║     in Spotify Developer Dashboard.                          ║")
                        Log.e(TAG, "║                                                              ║")
                        Log.e(TAG, "║  3. manifestPlaceholders redirectHostName in build.gradle    ║")
                        Log.e(TAG, "║     does not match the host portion of your redirect URI.    ║")
                        Log.e(TAG, "║     (Run the Expo config plugin to regenerate.)              ║")
                        Log.e(TAG, "║                                                              ║")
                        Log.e(TAG, "║  4. Installed Spotify version is too old to support          ║")
                        Log.e(TAG, "║     app-switch auth.                                         ║")
                        Log.e(TAG, "╚══════════════════════════════════════════════════════════════╝")
                        Log.e(TAG, "")
                    } else {
                        Log.w(TAG, "Authorization returned EMPTY - user likely cancelled")
                    }
                    module?.onAuthorizationError(SpotifyAuthException.UserCancelled())
                }
                else -> {
                    Log.e(TAG, "Unexpected Spotify response type: ${response.type}")
                    module?.onAuthorizationError(
                        SpotifyAuthException.AuthenticationFailed("Unexpected response type: ${response.type}")
                    )
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Exception in handleActivityResult: ${e.message}", e)
            module?.onAuthorizationError(
                SpotifyAuthException.AuthenticationFailed("Error processing auth result: ${e.message}")
            )
        }
    }

    /**
     * Handle the Spotify auth callback delivered via onNewIntent (browser-based flow).
     * Called by the module's OnNewIntent handler after openLoginInBrowser() completes.
     */
    fun handleNewIntent(intent: Intent) {
        Log.d(TAG, "handleNewIntent called - action=${intent.action}, data=${intent.data}")

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

        try {
            val response = AuthorizationClient.getResponse(Activity.RESULT_OK, intent)
            Log.d(TAG, "Spotify response type: ${response.type}")

            when (response.type) {
                AuthorizationResponse.Type.CODE -> {
                    val code = response.code
                    secureLog("Authorization code received, length=${code?.length ?: 0}")
                    if (code != null) {
                        exchangeCodeForToken(code)
                    } else {
                        Log.e(TAG, "Authorization code was null despite CODE response type")
                        module?.onAuthorizationError(
                            SpotifyAuthException.AuthenticationFailed("No authorization code received")
                        )
                    }
                }
                AuthorizationResponse.Type.ERROR -> {
                    val errorMsg = response.error ?: "Unknown error"
                    Log.e(TAG, "Spotify authorization error: $errorMsg")
                    if (errorMsg.contains("access_denied", ignoreCase = true) ||
                        errorMsg.contains("cancelled", ignoreCase = true)) {
                        module?.onAuthorizationError(SpotifyAuthException.UserCancelled())
                    } else {
                        module?.onAuthorizationError(SpotifyAuthException.AuthorizationError(errorMsg))
                    }
                }
                AuthorizationResponse.Type.EMPTY -> {
                    Log.w(TAG, "Browser auth returned EMPTY - user likely cancelled")
                    module?.onAuthorizationError(SpotifyAuthException.UserCancelled())
                }
                else -> {
                    Log.e(TAG, "Unexpected Spotify response type: ${response.type}")
                    module?.onAuthorizationError(
                        SpotifyAuthException.AuthenticationFailed("Unexpected response type: ${response.type}")
                    )
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Exception in handleNewIntent: ${e.message}", e)
            module?.onAuthorizationError(
                SpotifyAuthException.AuthenticationFailed("Error processing auth result: ${e.message}")
            )
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
