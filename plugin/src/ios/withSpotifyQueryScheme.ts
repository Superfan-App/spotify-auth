import { ConfigPlugin, withInfoPlist } from "expo/config-plugins";

import { SpotifyConfig } from "../types";

const spotifyScheme = "spotify";

export const withSpotifyQueryScheme: ConfigPlugin<SpotifyConfig> = (config) =>
  withInfoPlist(config, (config) => {
    if (!config.modResults.LSApplicationQueriesSchemes) {
      config.modResults.LSApplicationQueriesSchemes = [];
    }

    if (!config.modResults.LSApplicationQueriesSchemes.includes(spotifyScheme)) {
      config.modResults.LSApplicationQueriesSchemes.push(spotifyScheme)
    }

    return config;
  });