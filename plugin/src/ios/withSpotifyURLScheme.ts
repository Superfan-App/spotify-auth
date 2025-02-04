import { type ConfigPlugin, withInfoPlist } from "expo/config-plugins";

import { SpotifyConfig } from "../types";

function validateScheme(scheme: string) {
  if (!scheme) {
    throw new Error("URL scheme is required");
  }
  
  // Ensure scheme follows URL scheme naming conventions
  if (!/^[a-z][a-z0-9+.-]*$/i.test(scheme)) {
    throw new Error("Invalid URL scheme format. Scheme should start with a letter and contain only letters, numbers, plus, period, or hyphen.");
  }
}

export const withSpotifyURLScheme: ConfigPlugin<SpotifyConfig> = (
  config,
  { scheme }
) => {
  validateScheme(scheme);
  
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