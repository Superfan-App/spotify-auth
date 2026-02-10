// src/index.tsx

import React, { useContext, useEffect, useState, useCallback } from "react";

import {
  SpotifyAuthContext,
  SpotifyAuthContextInstance,
  SpotifyAuthState,
  type AuthorizeConfig,
  type SpotifyAuthError,
  type SpotifyAuthEvent,
} from "./SpotifyAuth.types";
import SpotifyAuthModule from "./SpotifyAuthModule";

function addAuthListener(listener: (event: SpotifyAuthEvent) => void) {
  const eventName = SpotifyAuthModule.AuthEventName;
  return SpotifyAuthModule.addListener(eventName, listener);
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
  const [authState, setAuthState] = useState<SpotifyAuthState>({
    accessToken: null,
    refreshToken: null,
    expiresIn: null,
    tokenType: null,
    scope: null,
  });
  const [isAuthenticating, setIsAuthenticating] = useState(false);
  const [error, setError] = useState<SpotifyAuthError | null>(null);

  const authorize = useCallback(
    async (config: AuthorizeConfig): Promise<void> => {
      try {
        setIsAuthenticating(true);
        setError(null);
        await SpotifyAuthModule.authorize(config);
      } catch (err) {
        // Handle structured errors from the native layer
        if (err && typeof err === 'object' && 'type' in err) {
          setError(err as SpotifyAuthError);
        } else {
          // Create a generic error structure for unknown errors
          setError({
            type: 'unknown_error',
            message: err instanceof Error ? err.message : 'Authorization failed',
            details: {
              error_code: 'unknown',
              recoverable: false
            }
          });
        }
        throw err;
      }
    },
    [],
  );

  useEffect(() => {
    const subscription = addAuthListener((data) => {

      // Only update state if we receive a token
      if (data.token) {
        setAuthState({
          accessToken: data.token,
          refreshToken: data.refreshToken,
          expiresIn: data.expiresIn,
          tokenType: data.tokenType,
          scope: data.scope,
        });
        setIsAuthenticating(false);
        setError(null);
      }

      // Only set error if we have no token and there's an error
      if (!data.token && data.error) {
        setAuthState({
          accessToken: null,
          refreshToken: null,
          expiresIn: null,
          tokenType: null,
          scope: null,
        });
        setError(data.error);
        setIsAuthenticating(false);
      }

      // Handle ambiguous state: no token and no error (e.g. sign-out event)
      if (!data.token && !data.error) {
        setAuthState({
          accessToken: null,
          refreshToken: null,
          expiresIn: null,
          tokenType: null,
          scope: null,
        });
        setIsAuthenticating(false);
      }
    });
    return () => subscription.remove();
  }, []);

  return (
    <SpotifyAuthContextInstance.Provider
      value={{
        authState,
        authorize,
        isAuthenticating,
        error
      }}
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
