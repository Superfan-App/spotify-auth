import { EventEmitter } from "expo-modules-core";
import React, { createContext, useContext, useEffect, useState } from "react";

import { SpotifyAuthorizationData, SpotifyContext } from "./SpotifyAuth.types";
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

const SpotifyAuthContext = createContext<SpotifyContext>({
  accessToken: null,
  authorize,
});

interface SpotifyProviderProps {
  children: React.ReactNode;
}

export function SpotifyProvider({
  children,
}: SpotifyProviderProps): JSX.Element {
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
    <SpotifyAuthContext.Provider value={{ accessToken: token, authorize }}>
      {children}
    </SpotifyAuthContext.Provider>
  );
}

export function useSpotify(): SpotifyContext {
  const context = useContext(SpotifyAuthContext);
  if (!context) {
    throw new Error("useSpotify must be used within a SpotifyProvider");
  }
  return context;
}
