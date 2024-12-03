import { NativeModule, requireNativeModule } from "expo";

import { SpotifyOAuthModuleEvents } from "./SpotifyOAuth.types";

declare class SpotifyOAuthModule extends NativeModule<SpotifyOAuthModuleEvents> {
  PI: number;
  hello(): string;
}

// This call loads the native module object from the JSI.
export default requireNativeModule<SpotifyOAuthModule>("SpotifyOAuth");
