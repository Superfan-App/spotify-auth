import { ConfigPlugin, createRunOncePlugin, withInfoPlist } from '@expo/config-plugins';
import { version, name } from '../package.json';

const withSpotifyOAuthInternal: ConfigPlugin = (config) => {
  try {
    // Modify iOS plist
    return withInfoPlist(config, (config) => {
      const infoPlist = config.modResults;
      
      // Ensure LSApplicationQueriesSchemes exists and includes 'spotify'
      if (!Array.isArray(infoPlist.LSApplicationQueriesSchemes)) {
        infoPlist.LSApplicationQueriesSchemes = [];
      }
      
      if (!infoPlist.LSApplicationQueriesSchemes.includes('spotify')) {
        infoPlist.LSApplicationQueriesSchemes.push('spotify');
      }

      console.log(`[${name}] Added spotify to LSApplicationQueriesSchemes`);
      
      return config;
    });
  } catch (error) {
    console.error(`[${name}] Error in plugin:`, error);
    throw error;
  }
};

// This creates the plugin and ensures it only runs once per prebuild
export const withSpotifyOAuth = createRunOncePlugin(
  withSpotifyOAuthInternal,
  name,
  version
); 