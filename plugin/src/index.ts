// plugin/src/index.ts

import { type ConfigPlugin, createRunOncePlugin, withInfoPlist } from '@expo/config-plugins'
import { SpotifyConfig } from './types.js'

const pkg = require('../../package.json');

function validateSpotifyConfig(config: SpotifyConfig) {
  if (!config.clientID) throw new Error("Spotify clientID is required")
  if (!config.scheme) throw new Error("URL scheme is required")
  if (!config.callback) throw new Error("Callback path is required")
  if (!config.tokenSwapURL) throw new Error("Token swap URL is required")
  if (!config.tokenRefreshURL) throw new Error("Token refresh URL is required")
  if (!Array.isArray(config.scopes) || config.scopes.length === 0) {
    throw new Error("At least one scope is required")
  }

  // Validate URL scheme format
  if (!/^[a-z][a-z0-9+.-]*$/i.test(config.scheme)) {
    throw new Error("Invalid URL scheme format. Scheme should start with a letter and contain only letters, numbers, plus, period, or hyphen.")
  }

  // Validate callback path
  if (!/^[a-z0-9\-_\/]+$/i.test(config.callback)) {
    throw new Error("Invalid callback path format. Path should contain only letters, numbers, hyphens, underscores, and forward slashes.")
  }

  // Validate token URLs use HTTPS
  if (!config.tokenSwapURL.startsWith('https://')) {
    throw new Error("Token swap URL must use HTTPS")
  }
  if (!config.tokenRefreshURL.startsWith('https://')) {
    throw new Error("Token refresh URL must use HTTPS")
  }
}

const withSpotifyURLSchemes: ConfigPlugin<SpotifyConfig> = (config, props) => {
  return withInfoPlist(config, (config) => {
    // Add URL scheme configuration
    if (!config.modResults.CFBundleURLTypes) {
      config.modResults.CFBundleURLTypes = [];
    }
    config.modResults.CFBundleURLTypes.push({
      CFBundleURLSchemes: [props.scheme],
      CFBundleURLName: props.scheme
    });

    // Add Spotify query scheme
    if (!config.modResults.LSApplicationQueriesSchemes) {
      config.modResults.LSApplicationQueriesSchemes = [];
    }
    if (!config.modResults.LSApplicationQueriesSchemes.includes('spotify')) {
      config.modResults.LSApplicationQueriesSchemes.push('spotify');
    }

    return config;
  });
};

const withSpotifyConfiguration: ConfigPlugin<SpotifyConfig> = (config, props) => {
  return withInfoPlist(config, (config) => {
    // Construct the redirect URL from scheme and callback
    const redirectUrl = `${props.scheme}://${props.callback}`

    // Add Spotify configuration
    config.modResults.SpotifyClientID = props.clientID;
    config.modResults.SpotifyRedirectURL = redirectUrl;
    config.modResults.SpotifyScopes = props.scopes;
    config.modResults.SpotifyTokenSwapURL = props.tokenSwapURL;
    config.modResults.SpotifyTokenRefreshURL = props.tokenRefreshURL;

    return config;
  });
};

const withSpotifyAuth: ConfigPlugin<SpotifyConfig> = (config, props) => {
  // Ensure the config exists
  if (!props) {
    throw new Error(
      'Missing Spotify configuration. Please provide clientID, scheme, callback, tokenSwapURL, tokenRefreshURL, and scopes in your app.config.js/app.json.'
    );
  }

  validateSpotifyConfig(props);

  // Apply configurations in sequence
  config = withSpotifyConfiguration(config, props);
  config = withSpotifyURLSchemes(config, props);

  return config;
};

export default createRunOncePlugin(withSpotifyAuth, pkg.name, pkg.version);
