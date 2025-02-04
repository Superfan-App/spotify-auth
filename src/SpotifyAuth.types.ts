import { createContext } from "react";

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
  authorize: () => void;
}

export const SpotifyAuthContextInstance = createContext<SpotifyAuthContext>({
  accessToken: null,
  authorize: () => { },
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
