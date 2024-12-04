import { EventEmitter } from "expo-modules-core";
import React, { useContext, useEffect, useState } from "react";

import {
  SpotifyAuthorizationData,
  SpotifyAuthContext,
  SpotifyAuthContextInstance,
} from "./SpotifyAuth.types";
import SpotifyAuthModule from "./SpotifyAuthModule";

// First define the event name as a string literal type
type SpotifyAuthEventName = "onSpotifyAuth"; // This should match SpotifyAuthModule.AuthEventName

// Then use that type for events
type SpotifyEvents = {
  [K in SpotifyAuthEventName]: (data: SpotifyAuthorizationData) => void;
};

// Create a properly typed emitter
const emitter = new EventEmitter<SpotifyEvents>();

function addAuthListener(listener: (data: SpotifyAuthorizationData) => void) {
  // Assert the event name is of the correct type
  const eventName = SpotifyAuthModule.AuthEventName as SpotifyAuthEventName;
  return emitter.addListener(eventName, listener);
}

/**
 * Prompts the user to log in to Spotify and authorize your application.
 * @param playURI Optional URI to play after authorization
 */
function authorize(playURI?: string): void {
  SpotifyAuthModule.authorize(playURI);
}

interface SpotifyAuthProviderProps {
  children: React.ReactNode;
}

export function SpotifyAuthProvider({
  children,
}: SpotifyAuthProviderProps): JSX.Element {
  const [token, setToken] = useState<string | null>(null);

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
    <SpotifyAuthContextInstance.Provider value={{ accessToken: token, authorize }}>
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
