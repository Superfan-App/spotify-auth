# @superfan-app/spotify-auth

A modern Expo module for Spotify authentication in React Native apps. This module provides a seamless OAuth flow with proper token management and automatic refresh handling.

## Features

- 🔐 Complete Spotify OAuth implementation
- 🔄 Automatic token refresh
- 📱 iOS support via native Spotify SDK
- 🤖 Android support via Spotify Auth Library
- ⚡️ Modern Expo development workflow
- 🛡️ Secure token storage (Keychain on iOS, EncryptedSharedPreferences on Android)
- 🔧 TypeScript support
- 📝 Comprehensive error handling

## Installation

```bash
npx expo install @superfan-app/spotify-auth
```

This module requires the Expo Development Client (not compatible with Expo Go):

```bash
npx expo install expo-dev-client
```

## Configuration

1. Create a Spotify application in the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard)

2. Configure your app.json/app.config.js:

```json
{
  "expo": {
    "plugins": [
      [
        "@superfan-app/spotify-auth",
        {
          "clientID": "your_spotify_client_id",
          "scheme": "your-app-scheme",
          "callback": "callback",
          "tokenSwapURL": "https://your-backend.com/swap",
          "tokenRefreshURL": "https://your-backend.com/refresh",
          "scopes": [
            "user-read-email",
            "streaming"
          ]
        }
      ]
    ]
  }
}
```

3. Set up your redirect URI in the Spotify Dashboard:
   - Format: `your-app-scheme://callback`
   - Example: `my-spotify-app://callback`

4. **Android only:** Register your app's [SHA-1 fingerprint](https://developer.spotify.com/documentation/android/tutorials/application-fingerprints) in the Spotify Developer Dashboard.

5. Implement token swap/refresh endpoints on your backend (see Backend Requirements below)

## Usage

1. Wrap your app with the provider:

```tsx
import { SpotifyAuthProvider } from '@superfan-app/spotify-auth';

export default function App() {
  return (
    <SpotifyAuthProvider>
      <MainApp />
    </SpotifyAuthProvider>
  );
}
```

2. Use the hook in your components:

```tsx
import { useSpotifyAuth } from '@superfan-app/spotify-auth';

function MainScreen() {
  const { 
    authState,
    authorize,
    isAuthenticating,
    error
  } = useSpotifyAuth();

  useEffect(() => {
    if (!authState.accessToken && !isAuthenticating) {
      authorize({ showDialog: false });
    }
  }, []);

  if (isAuthenticating) {
    return <ActivityIndicator />;
  }

  if (error) {
    return <Text>Error: {error.message}</Text>;
  }

  if (!authState.accessToken) {
    return <Text>Not authenticated</Text>;
  }

  return <YourAuthenticatedApp token={authState.accessToken} />;
}
```

## API Reference

### SpotifyAuthProvider

Provider component that manages authentication state.

```tsx
<SpotifyAuthProvider>
  {children}
</SpotifyAuthProvider>
```

### useSpotifyAuth()

Hook for accessing authentication state and methods.

Returns:
- \`authState: SpotifyAuthState\` - Authentication state object containing:
  - \`accessToken: string | null\` - Current Spotify access token
  - \`refreshToken: string | null\` - Current refresh token
  - \`expiresIn: number | null\` - Token expiration time in seconds
  - \`tokenType: string | null\` - Token type (e.g. "Bearer")
  - \`scope: string | null\` - Granted scopes
- \`authorize(config: AuthorizeConfig): Promise<void>\` - Start authentication flow
  - \`config.showDialog?: boolean\` - Whether to force the auth dialog
  - \`config.campaign?: string\` - Campaign identifier for attribution
- \`isAuthenticating: boolean\` - Authentication in progress
- \`error: SpotifyAuthError | null\` - Last error (object with \`type\`, \`message\`, and \`details\`)

### Available Scopes

All standard Spotify scopes are supported:
- \`app-remote-control\`
- \`playlist-modify-private\`
- \`playlist-modify-public\`
- \`playlist-read-collaborative\`
- \`playlist-read-private\`
- \`streaming\`
- \`user-follow-modify\`
- \`user-follow-read\`
- \`user-library-modify\`
- \`user-library-read\`
- \`user-modify-playback-state\`
- \`user-read-currently-playing\`
- \`user-read-email\`
- \`user-read-playback-position\`
- \`user-read-playback-state\`
- \`user-read-private\`
- \`user-read-recently-played\`
- \`user-top-read\`
- \`openid\`

## Backend Requirements

You need to implement two endpoints:

1. Token Swap Endpoint (\`tokenSwapURL\`):
   - Receives authorization code
   - Exchanges it for access/refresh tokens using your client secret
   - Returns tokens to the app

2. Token Refresh Endpoint (\`tokenRefreshURL\`):
   - Receives refresh token
   - Gets new access token from Spotify
   - Returns new access token to the app

Example response format for both endpoints:
```json
{
  "access_token": "new_access_token",
  "refresh_token": "new_refresh_token",
  "expires_in": 3600
}
```

## Development Workflow

1. Clean installation:
```bash
npm install
npm run build
```

2. Clean build:
```bash
npx expo prebuild --clean
```

3. Run on iOS:
```bash
npx expo run:ios
```

4. Run on Android:
```bash
npx expo run:android
```

## Troubleshooting

### Common Issues

1. "Cannot find native module 'SpotifyAuth'":
   ```bash
   npx expo prebuild --clean
   npx expo run:ios
   ```

2. Build errors:
   ```bash
   npm run clean
   npm run build
   npx expo prebuild --clean
   ```

3. Authentication errors:
   - Verify your client ID
   - Check redirect URI in Spotify Dashboard
   - Ensure HTTPS for token endpoints
   - Verify requested scopes

## Security

- Access tokens are stored in memory
- Refresh tokens are securely stored in Keychain (iOS) / EncryptedSharedPreferences (Android)
- HTTPS required for token endpoints
- Automatic token refresh
- Proper error handling and recovery

## Requirements

- Expo SDK 53+
- iOS 15.1+
- Android API 24+ (Android 7.0+)
- Swift 5.9 (Xcode 15+)
- Node.js 20.0+
- Expo Development Client

## Platform Notes

### iOS

- The Spotify SDK is bundled as a vendored `SpotifyiOS.xcframework`. CocoaPods configures header and framework search paths automatically. You do not need to add manual `HEADER_SEARCH_PATHS` or `FRAMEWORK_SEARCH_PATHS`.
- If you hit CocoaPods build issues after installing, try:
```bash
cd ios
pod deintegrate
pod install --repo-update
```

### Android

The Spotify Auth Library (`spotify-auth-release-2.1.0.aar`) v2.1.0 is bundled in `android/Frameworks/`. It handles both app-switch auth (when Spotify is installed) and WebView fallback (when it's not).

#### Android Setup (if iOS is already configured)

If you already have iOS working, Android requires no changes to your `app.config.js` — the same plugin config drives both platforms. However, you do need to complete these additional steps in the Spotify Developer Dashboard:

1. **Register your Android package name and SHA-1 fingerprint** in the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard):
   - Go to your app → Edit Settings → Android Packages
   - Add your package name (e.g. `com.yourcompany.yourapp`)
   - Add your SHA-1 fingerprint(s)

2. **Generate your SHA-1 fingerprint:**

   For **debug** builds:
   ```bash
   keytool -alias androiddebugkey -keystore ~/.android/debug.keystore -list -v | grep SHA1
   ```
   Default password: `android`

   For **release** builds:
   ```bash
   keytool -alias <RELEASE_KEY_ALIAS> -keystore <RELEASE_KEYSTORE_PATH> -list -v | grep SHA1
   ```

   > We strongly recommend registering both debug and release fingerprints. See [Application Fingerprints](https://developer.spotify.com/documentation/android/tutorials/application-fingerprints) for details.

3. **Ensure the redirect URI** (`your-app-scheme://callback`) is added in the Spotify Dashboard under "Redirect URIs" (this is shared with iOS — likely already done).

4. **Rebuild your app:**
   ```bash
   npx expo prebuild --clean
   npx expo run:android
   ```

#### What the config plugin does (Android)

The Expo config plugin automatically handles:
- Injecting `<meta-data>` entries into `AndroidManifest.xml` for `SpotifyClientID`, `SpotifyRedirectURL`, `SpotifyScopes`, `SpotifyTokenSwapURL`, and `SpotifyTokenRefreshURL`
- Adding an `<intent-filter>` to your main activity for the redirect URI scheme and host

You do **not** need to manually edit `AndroidManifest.xml`.

#### Android-specific behavior

- The `campaign` parameter in `AuthorizeConfig` is **ignored** on Android (not supported by the Spotify Android auth library).
- Secure token storage uses `EncryptedSharedPreferences` (AES-256) instead of Keychain.
- When the Spotify app is installed, authentication uses an app-switch flow (no password entry needed). When it's not installed, a WebView fallback is used automatically.
- Authentication retry for user-interactive flows (e.g. the initial authorization) cannot be retried automatically — the error is reported to JS so your app can prompt the user to try again.
