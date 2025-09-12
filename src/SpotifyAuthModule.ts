// src/SpotifyAuthModule.ts

import { requireNativeModule, NativeModule } from "expo-modules-core";
import type { AuthorizeConfig, SpotifyAuthEvent } from "./SpotifyAuth.types";

export type SpotifyAuthEvents = {
  onSpotifyAuth(event: SpotifyAuthEvent): void;
};

export declare class SpotifyAuthModule extends NativeModule<SpotifyAuthEvents> {
  readonly AuthEventName: 'onSpotifyAuth';
  readonly authorize: (config: AuthorizeConfig) => Promise<void>;
}

// This call loads the native module object from the JSI.
export default requireNativeModule("SpotifyAuth") as SpotifyAuthModule;

export const AuthEventName = "onSpotifyAuth" as const;
