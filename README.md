# spotify-auth

A React Native module for Spotify authentication, built with Expo modules.

# Installation

```bash
npm install @superfan-app/spotify-auth
```

# Configuration

### iOS

1. Run `npx pod-install` after installing the npm package.

2. Add the following to your `Info.plist`:

```xml
<key>SpotifyClientID</key>
<string>YOUR_CLIENT_ID</string>
<key>SpotifyScheme</key>
<string>YOUR_URL_SCHEME</string>
<key>SpotifyCallback</key>
<string>YOUR_CALLBACK_PATH</string>
<key>SpotifyScopes</key>
<array>
    <string>user-read-private</string>
    <!-- Add other required scopes -->
</array>
```

# Usage

```tsx
import { SpotifyAuthProvider, useSpotifyAuth } from '@superfan-app/spotify-auth';

// Wrap your app with the provider
function App() {
  return (
    <SpotifyAuthProvider>
      <YourApp />
    </SpotifyAuthProvider>
  );
}

// Use the hook in your components
function YourApp() {
  const { accessToken, authorize } = useSpotifyAuth();

  const handleLogin = () => {
    // Optional playURI to start playing after auth
    authorize();
  };

  if (!accessToken) {
    return <Button onPress={handleLogin} title="Login with Spotify" />;
  }

  return <YourAuthenticatedApp />;
}
```

The module provides:
- `SpotifyAuthProvider`: Context provider that manages the Spotify authentication state
- `useSpotifyAuth`: Hook that provides:
  - `accessToken`: Current Spotify access token (null if not authenticated)
  - `authorize(playURI?: string)`: Function to initiate Spotify authorization
