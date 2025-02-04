import { EventEmitter } from "expo-modules-core";
import React, { useContext, useEffect, useState, useCallback } from "react";

import {
  SpotifyAuthorizationData,
  SpotifyAuthContext,
  SpotifyAuthContextInstance,
  type AuthorizeConfig,
} from "./SpotifyAuth.types";
import SpotifyAuthModule from "./SpotifyAuthModule";

// First define the event name as a string literal type
type SpotifyAuthEventName = "onSpotifyAuth"; // This should match SpotifyAuthModule.AuthEventName

// Create a properly typed emitter
const emitter = new EventEmitter(SpotifyAuthModule);

function addAuthListener(listener: (data: SpotifyAuthorizationData) => void) {
  // Assert the event name is of the correct type
  const eventName = SpotifyAuthModule.AuthEventName as SpotifyAuthEventName;
  return emitter.addListener(eventName, listener);
}

/**
 * Prompts the user to log in to Spotify and authorize your application.
 */
export function authorize(config: AuthorizeConfig): void {
  SpotifyAuthModule.authorize(config);
}

interface SpotifyAuthProviderProps {
  children: React.ReactNode;
}

export function SpotifyAuthProvider({
  children,
}: SpotifyAuthProviderProps): JSX.Element {
  const [token, setToken] = useState<string | null>(null);
  const [isAuthenticating, setIsAuthenticating] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const authorize = useCallback(
    async (config: AuthorizeConfig): Promise<void> => {
      try {
        setIsAuthenticating(true);
        setError(null);
        await SpotifyAuthModule.authorize(config);
      } catch (err) {
        setError(err instanceof Error ? err.message : "Authorization failed");
        throw err;
      } finally {
        setIsAuthenticating(false);
      }
    },
    [],
  );

  useEffect(() => {
    const subscription = addAuthListener((data) => {
      setToken(data.token);
      if (data.error) {
        console.error(`Spotify auth error: ${data.error}`);
      }
    });
    return () => subscription.remove();
  }, []);

  return (
    <SpotifyAuthContextInstance.Provider
      value={{ accessToken: token, authorize, isAuthenticating, error }}
    >
      {children}
    </SpotifyAuthContextInstance.Provider>
  );
}

export function useSpotifyAuth(): SpotifyAuthContext {
  const context = useContext(SpotifyAuthContextInstance);
  if (!context) {
    throw new Error("useSpotifyAuth must be used within a SpotifyAuthProvider");
  }
  return context;
}
