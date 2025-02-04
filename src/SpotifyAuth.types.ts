import { createContext } from "react";

/**
 * Event data structure for Spotify authorization events
 */
export interface SpotifyAuthEvent {
  success: boolean;
  token: string | null;
  error?: string;
}

/**
 * Data returned from the Spotify authorization process
 */
export interface SpotifyAuthorizationData {
  /** Whether the authorization was successful */
  success: boolean;
  /** The access token if authorization was successful, null otherwise */
  token: string | null;
  /** Error message if authorization failed */
  error?: string;
}

/**
 * Configuration for the authorization request
 */
export interface AuthorizeConfig {
  /** Spotify Client ID */
  clientId: string;
  /** OAuth redirect URL */
  redirectUrl: string;
  /** Whether to show the auth dialog */
  showDialog?: boolean;
}

/**
 * Props for the SpotifyAuthView component
 */
export interface SpotifyAuthViewProps {
  /** The name identifier for the auth view */
  name: string;
}

/**
 * Context for Spotify authentication state and actions
 */
export interface SpotifyAuthContext {
  /** The current Spotify access token, null if not authenticated */
  accessToken: string | null;
  /** Function to initiate Spotify authorization */
  authorize: (config: AuthorizeConfig) => Promise<void>;
  /** Whether authorization is in progress */
  isAuthenticating: boolean;
  /** Last error that occurred during authentication */
  error: string | null;
}

export const SpotifyAuthContextInstance = createContext<SpotifyAuthContext>({
  accessToken: null,
  authorize: async () => {},
  isAuthenticating: false,
  error: null,
});

export interface SpotifyAuthOptions {
  clientId: string;
  redirectUrl: string;
  showDialog?: boolean;
  tokenRefreshFunction?: (data: SpotifyTokenResponse) => void;
}

/**
 * Response data from Spotify token endpoint
 */
export interface SpotifyTokenResponse {
  access_token: string;
  token_type: string;
  expires_in: number;
  refresh_token?: string;
  scope: string;
}
