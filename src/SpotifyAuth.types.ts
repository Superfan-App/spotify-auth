// src/SpotifyAuth.types.ts

import { createContext } from "react";

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
  | 'openid';

/**
 * Event data structure for Spotify authorization events
 */
export interface SpotifyAuthEvent {
  success: boolean;
  token: string | null;
  refreshToken: string | null;
  expiresIn: number | null;
  tokenType: string | null;
  scope: string | null;
  error?: SpotifyAuthError;
}

/**
 * Data returned from the Spotify authorization process
 */
export interface SpotifyAuthorizationData {
  /** Whether the authorization was successful */
  success: boolean;
  /** The access token if authorization was successful, null otherwise */
  token: string | null;
  /** The refresh token if authorization was successful, null otherwise */
  refreshToken: string | null;
  /** The token expiration time in seconds if authorization was successful, null otherwise */
  expiresIn: number | null;
  /** The token type (e.g. "Bearer") if authorization was successful, null otherwise */
  tokenType: string | null;
  /** The granted scopes if authorization was successful, null otherwise */
  scope: string | null;
  /** Error information if authorization failed */
  error?: SpotifyAuthError;
}

/**
 * Possible error types that can occur during Spotify authentication
 */
export type SpotifyAuthError = {
  /** The type of error that occurred */
  type: 
    | "configuration_error"    // Missing or invalid configuration
    | "network_error"         // Network-related issues
    | "token_error"          // Issues with token exchange/refresh
    | "authorization_error"   // User-facing authorization issues
    | "server_error"         // Backend server issues
    | "unknown_error";       // Unexpected errors
  /** Human-readable error message */
  message: string;
  /** Additional error details */
  details: {
    /** Specific error code for more granular error handling */
    error_code: string;
    /** Whether the error can be recovered from */
    recoverable: boolean;
    /** Retry strategy information if applicable */
    retry?: {
      /** Type of retry strategy */
      type: "fixed" | "exponential";
      /** For fixed retry: number of attempts */
      attempts?: number;
      /** For fixed retry: delay between attempts in seconds */
      delay?: number;
      /** For exponential backoff: maximum number of attempts */
      max_attempts?: number;
      /** For exponential backoff: initial delay in seconds */
      initial_delay?: number;
    };
  };
}

/**
 * Configuration for the authorization request.
 * These are runtime options that can be changed between auth attempts.
 */
export interface AuthorizeConfig {
  /** Whether to show the auth dialog */
  showDialog?: boolean;
  /** Campaign identifier for attribution */
  campaign?: string;
}

/**
 * Props for the SpotifyAuthView component
 */
export interface SpotifyAuthViewProps {
  /** The name identifier for the auth view */
  name: string;
}

/**
 * Spotify authentication state containing all token-related information
 */
export interface SpotifyAuthState {
  /** The current Spotify access token, null if not authenticated */
  accessToken: string | null;
  /** The current refresh token, null if not authenticated */
  refreshToken: string | null;
  /** The token expiration time in seconds, null if not authenticated */
  expiresIn: number | null;
  /** The token type, null if not authenticated */
  tokenType: string | null;
  /** The token scope, null if not authenticated */
  scope: string | null;
}

/**
 * Context for Spotify authentication state and actions
 */
export interface SpotifyAuthContext {
  /** The complete Spotify authentication state */
  authState: SpotifyAuthState;
  /** Function to initiate Spotify authorization */
  authorize: (config: AuthorizeConfig) => Promise<void>;
  /** Whether authorization is in progress */
  isAuthenticating: boolean;
  /** Last error that occurred during authentication */
  error: SpotifyAuthError | null;
}

export const SpotifyAuthContextInstance = createContext<SpotifyAuthContext>({
  authState: {
    accessToken: null,
    refreshToken: null,
    expiresIn: null,
    tokenType: null,
    scope: null,
  },
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
