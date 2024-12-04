import { requireNativeModule } from "expo-modules-core";

// This call loads the native module object from the JSI.
export default requireNativeModule("SpotifyAuth");

export const AuthEventName = "onSpotifyAuth" as const;
