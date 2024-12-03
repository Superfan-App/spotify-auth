// Reexport the native module. On web, it will be resolved to SpotifyOAuthModule.web.ts
// and on native platforms to SpotifyOAuthModule.ts
export { default } from "./SpotifyOAuthModule";
export * from "./SpotifyOAuth.types";
