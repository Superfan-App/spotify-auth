import { type ConfigPlugin, withInfoPlist } from 'expo/config-plugins'

import { SpotifyConfig } from './types'

const withSpotifyOAuthConfigIOS: ConfigPlugin<SpotifyConfig> = (config, spotifyConfig) => {
  return withInfoPlist(config, (config) => {
    config.modResults.SpotifyClientID = spotifyConfig.clientID;
    config.modResults.SpotifyScheme = spotifyConfig.scheme;
    config.modResults.SpotifyCallback = spotifyConfig.callback;
    config.modResults.SpotifyScopes = spotifyConfig.scopes;
    config.modResults.tokenRefreshURL = spotifyConfig.tokenRefreshURL;
    config.modResults.tokenSwapURL = spotifyConfig.tokenSwapURL;
    return config;
  });
};

export const withSpotifyOAuthConfig: ConfigPlugin<SpotifyConfig> = (config, spotifyConfig) => {
  config = withSpotifyOAuthConfigIOS(config, spotifyConfig)
  return config
}