# @superfan-app/spotify-auth

A modern Expo module for Spotify authentication in React Native apps. This module provides a seamless OAuth flow with proper token management and automatic refresh handling.

## Features

- 🔐 Complete Spotify OAuth implementation
- 🔄 Automatic token refresh
- 📱 iOS support via native SDK
- ⚡️ Modern Expo development workflow
- 🛡️ Secure token storage
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

4. Implement token swap/refresh endpoints on your backend (see Backend Requirements below)

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
    accessToken,
    authorize,
    isAuthenticating,
    error
  } = useSpotifyAuth();

  useEffect(() => {
    if (!accessToken && !isAuthenticating) {
      authorize();
    }
  }, []);

  if (isAuthenticating) {
    return <ActivityIndicator />;
  }

  if (error) {
    return <Text>Error: {error}</Text>;
  }

  if (!accessToken) {
    return <Text>Not authenticated</Text>;
  }

  return <YourAuthenticatedApp token={accessToken} />;
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
- \`accessToken: string | null\` - Current Spotify access token
- \`authorize(): Promise<void>\` - Start authentication flow
- \`isAuthenticating: boolean\` - Authentication in progress
- \`error: string | null\` - Last error message

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
- Refresh tokens are securely stored in Keychain
- HTTPS required for token endpoints
- Automatic token refresh
- Proper error handling and recovery

## Requirements

- Expo SDK 47+
- iOS 13.0+
- Node.js 14.0+
- Expo Development Client
