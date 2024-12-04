import { requireNativeModule } from "expo-modules-core";

interface SpotifyOAuthModule {
  PI: number;
  hello(): string;
}

// This call loads the native module object from the JSI.
export default requireNativeModule<SpotifyOAuthModule>("SpotifyOAuth");
