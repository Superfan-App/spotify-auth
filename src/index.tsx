import { EventEmitter } from "expo-modules-core";
import React, { useContext, useEffect, useState, useCallback } from "react";

import {
  SpotifyAuthorizationData,
  SpotifyAuthContext,
  SpotifyAuthContextInstance,
  SpotifyAuthState,
  type AuthorizeConfig,
  type SpotifyAuthError,
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
  console.log('[SpotifyAuth] Initiating authorization request');
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
        console.log('[SpotifyAuth] Starting authorization process in provider');
        console.log('[SpotifyAuth] Authorization config:', JSON.stringify(config));
        setIsAuthenticating(true);
        setError(null);
        await SpotifyAuthModule.authorize(config);
      } catch (err) {
        console.error('[SpotifyAuth] Authorization error:', err);
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
    console.log('[SpotifyAuth] Setting up auth listener');
    const subscription = addAuthListener((data) => {
      console.log('[SpotifyAuth] Received auth event:', JSON.stringify(data));

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
        console.error('[SpotifyAuth] Auth event error:', data.error);
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
