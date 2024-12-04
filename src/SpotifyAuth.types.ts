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
  authorize: (playURI?: string) => void;
}

export const SpotifyAuthContextInstance = createContext<SpotifyAuthContext>({
  accessToken: null,
  authorize: () => {},
});
