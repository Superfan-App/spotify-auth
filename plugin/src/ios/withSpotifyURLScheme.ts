import { ConfigPlugin, withInfoPlist } from "expo/config-plugins";

import { ISpotifyConfig } from "../types";

export const withSpotifyURLScheme: ConfigPlugin<ISpotifyConfig> = (
  config,
  { scheme }
) => {
  return withInfoPlist(config, (config) => {
    const bundleId = config.ios?.bundleIdentifier;
    const urlType = {
      CFBundleURLName: bundleId,
      CFBundleURLSchemes: [scheme],
    };
    if (!config.modResults.CFBundleURLTypes) {
      config.modResults.CFBundleURLTypes = [];
    }

    config.modResults.CFBundleURLTypes.push(urlType);

    return config;
  });
};