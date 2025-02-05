import { requireNativeModule } from "expo-modules-core";
import type { AuthorizeConfig } from "./SpotifyAuth.types";

interface SpotifyAuthModule {
  readonly AuthEventName: string;
  authorize(config: AuthorizeConfig): Promise<void>;
}

// This call loads the native module object from the JSI.
export default requireNativeModule("SpotifyAuth") as SpotifyAuthModule;

export const AuthEventName = "onSpotifyAuth" as const;
