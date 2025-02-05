/**
 * Available Spotify authorization scopes.
 * @see https://developer.spotify.com/documentation/general/guides/authorization/scopes/
 */
export type SpotifyScopes =
  | 'app-remote-control'
  | 'playlist-modify-private'
  | 'playlist-modify-public'
  | 'playlist-read-collaborative'
  | 'playlist-read-private'
  | 'streaming'
  | 'user-follow-modify'
  | 'user-follow-read'
  | 'user-library-modify'
  | 'user-library-read'
  | 'user-modify-playback-state'
  | 'user-read-currently-playing'
  | 'user-read-email'
  | 'user-read-playback-position'
  | 'user-read-playback-state'
  | 'user-read-private'
  | 'user-read-recently-played'
  | 'user-top-read'
  | 'openid'

/**
 * Configuration options for the Spotify OAuth module.
 * This should be provided in your app.config.js or app.json under the "plugins" section.
 * 
 * @example
 * ```json
 * {
 *   "expo": {
 *     "plugins": [
 *       [
 *         "@superfan-app/spotify-auth",
 *         {
 *           "clientID": "your_spotify_client_id",
 *           "scheme": "your-app-scheme",
 *           "callback": "callback",
 *           "tokenSwapURL": "https://your-backend.com/swap",
 *           "tokenRefreshURL": "https://your-backend.com/refresh",
 *           "scopes": ["user-read-email", "streaming"]
 *         }
 *       ]
 *     ]
 *   }
 * }
 * ```
 */
export interface SpotifyConfig {
  /**
   * Your Spotify application's client ID.
   * Obtain this from your Spotify Developer Dashboard.
   * @see https://developer.spotify.com/dashboard/
   */
  clientID: string;
  
  /**
   * The URL scheme to use for OAuth callbacks.
   * This should be unique to your app and match your Spotify app settings.
   * @example "my-spotify-app"
   */
  scheme: string;
  
  /**
   * The callback path for OAuth redirects.
   * This will be appended to your scheme to form the full redirect URI.
   * Full URI will be: `{scheme}://{callback}`
   * @example "callback"
   */
  callback: string;
  
  /**
   * URL for token swap endpoint.
   * This should be a secure (HTTPS) endpoint on your backend that handles
   * the code-for-token exchange with Spotify.
   * @example "https://your-backend.com/spotify/swap"
   */
  tokenSwapURL: string;
  
  /**
   * URL for token refresh endpoint.
   * This should be a secure (HTTPS) endpoint on your backend that handles
   * refreshing expired access tokens.
   * @example "https://your-backend.com/spotify/refresh"
   */
  tokenRefreshURL: string;
  
  /**
   * Array of Spotify authorization scopes.
   * These determine what permissions your app will request from users.
   * @see SpotifyScopes for available options
   * @example ["user-read-email", "streaming"]
   */
  scopes: SpotifyScopes[];
}