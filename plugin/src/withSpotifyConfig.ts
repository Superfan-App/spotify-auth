import { ConfigPlugin, withPlugins, createRunOncePlugin, withDangerousMod, withInfoPlist } from '@expo/config-plugins';
import { SpotifyConfig } from './types';
import fs from 'fs';
import path from 'path';

function validateSpotifyConfig(config: SpotifyConfig) {
  if (!config.clientID) throw new Error("Spotify clientID is required")
  if (!config.scheme) throw new Error("URL scheme is required")
  if (!config.callback) throw new Error("Callback path is required")
  if (!config.tokenSwapURL) throw new Error("Token swap URL is required")
  if (!config.tokenRefreshURL) throw new Error("Token refresh URL is required")
  if (!Array.isArray(config.scopes) || config.scopes.length === 0) {
    throw new Error("At least one scope is required")
  }
}

const withSpotifyOAuthConfigIOS: ConfigPlugin<SpotifyConfig> = (config, spotifyConfig) => {
  validateSpotifyConfig(spotifyConfig);
  
  return withInfoPlist(config, (config) => {
    config.modResults.SpotifyClientID = spotifyConfig.clientID;
    config.modResults.SpotifyScheme = spotifyConfig.scheme;
    config.modResults.SpotifyCallback = spotifyConfig.callback;
    config.modResults.SpotifyScopes = spotifyConfig.scopes;
    config.modResults.tokenRefreshURL = spotifyConfig.tokenRefreshURL;
    config.modResults.tokenSwapURL = spotifyConfig.tokenSwapURL;
    
    // Add URL scheme to Info.plist
    const urlTypes = config.modResults.CFBundleURLTypes || [];
    urlTypes.push({
      CFBundleURLSchemes: [spotifyConfig.scheme],
      CFBundleURLName: spotifyConfig.scheme
    });
    config.modResults.CFBundleURLTypes = urlTypes;
    
    return config;
  });
};

const withCleanup: ConfigPlugin = (config) => {
  return withDangerousMod(config, [
    'ios',
    async (config) => {
      const platformRoot = path.join(config.modRequest.projectRoot, 'ios');
      
      // Clean build directories
      const buildDirs = [
        path.join(platformRoot, 'build'),
        path.join(platformRoot, 'Pods'),
        path.join(platformRoot, 'DerivedData')
      ];
      
      for (const dir of buildDirs) {
        if (fs.existsSync(dir)) {
          fs.rmdirSync(dir, { recursive: true });
        }
      }
      
      return config;
    },
  ]);
};

const withSpotifyAuth: ConfigPlugin<SpotifyConfig> = (config, props) => {
  // Ensure the config exists
  if (!props) {
    throw new Error(
      'Missing Spotify configuration. Please provide clientID, scheme, callback, tokenSwapURL, tokenRefreshURL, and scopes in your app.config.js/app.json.'
    );
  }

  return withPlugins(config, [
    // Clean up first
    withCleanup,
    
    // Apply Spotify configurations
    [withSpotifyOAuthConfigIOS, props]
  ]);
};

export default createRunOncePlugin(withSpotifyAuth, 'spotify-auth', '0.1.21');