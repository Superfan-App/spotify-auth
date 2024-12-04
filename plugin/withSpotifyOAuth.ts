import { ConfigPlugin, createRunOncePlugin, withInfoPlist } from '@expo/config-plugins';
import { version } from '../package.json';

const withSpotifyOAuthInternal: ConfigPlugin = (config) => {
  // Modify iOS plist
  config = withInfoPlist(config, (config) => {
    const infoPlist = config.modResults;
    
    // Ensure LSApplicationQueriesSchemes exists and includes 'spotify'
    if (!Array.isArray(infoPlist.LSApplicationQueriesSchemes)) {
      infoPlist.LSApplicationQueriesSchemes = [];
    }
    
    if (!infoPlist.LSApplicationQueriesSchemes.includes('spotify')) {
      infoPlist.LSApplicationQueriesSchemes.push('spotify');
    }
    
    return config;
  });

  return config;
};

// This creates the plugin and ensures it only runs once per prebuild
export const withSpotifyOAuth = createRunOncePlugin(
  withSpotifyOAuthInternal,
  'spotify-oauth',
  version
); 