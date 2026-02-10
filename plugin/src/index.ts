// plugin/src/index.ts

import { type ConfigPlugin, createRunOncePlugin, withInfoPlist, withAndroidManifest, AndroidConfig } from '@expo/config-plugins'
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

// region Android config plugins

const withSpotifyAndroidManifest: ConfigPlugin<SpotifyConfig> = (config, props) => {
  return withAndroidManifest(config, (config) => {
    const mainApplication = AndroidConfig.Manifest.getMainApplicationOrThrow(config.modResults);

    // Construct the redirect URL from scheme and callback
    const redirectUrl = `${props.scheme}://${props.callback}`;

    // Add Spotify configuration as meta-data elements
    const metaDataEntries = [
      { name: 'SpotifyClientID', value: props.clientID },
      { name: 'SpotifyRedirectURL', value: redirectUrl },
      { name: 'SpotifyScopes', value: props.scopes.join(',') },
      { name: 'SpotifyTokenSwapURL', value: props.tokenSwapURL },
      { name: 'SpotifyTokenRefreshURL', value: props.tokenRefreshURL },
    ];

    if (!mainApplication['meta-data']) {
      mainApplication['meta-data'] = [];
    }

    for (const entry of metaDataEntries) {
      // Remove existing entry if present
      mainApplication['meta-data'] = mainApplication['meta-data'].filter(
        (item: any) => item.$?.['android:name'] !== entry.name
      );
      // Add new entry
      mainApplication['meta-data'].push({
        $: {
          'android:name': entry.name,
          'android:value': entry.value,
        },
      });
    }

    // Add intent filter to the main activity for the redirect URI scheme
    const mainActivity = AndroidConfig.Manifest.getMainActivityOrThrow(config.modResults);

    if (!mainActivity['intent-filter']) {
      mainActivity['intent-filter'] = [];
    }

    // Check if we already have a Spotify redirect intent filter
    const hasSpotifyIntentFilter = mainActivity['intent-filter'].some(
      (filter: any) =>
        filter.data?.some(
          (d: any) => d.$?.['android:scheme'] === props.scheme && d.$?.['android:host'] === props.callback
        )
    );

    if (!hasSpotifyIntentFilter) {
      mainActivity['intent-filter'].push({
        action: [{ $: { 'android:name': 'android.intent.action.VIEW' } }],
        category: [
          { $: { 'android:name': 'android.intent.category.DEFAULT' } },
          { $: { 'android:name': 'android.intent.category.BROWSABLE' } },
        ],
        data: [
          {
            $: {
              'android:scheme': props.scheme,
              'android:host': props.callback,
            },
          },
        ],
      });
    }

    return config;
  });
};

// endregion

const withSpotifyAuth: ConfigPlugin<SpotifyConfig> = (config, props) => {
  // Ensure the config exists
  if (!props) {
    throw new Error(
      'Missing Spotify configuration. Please provide clientID, scheme, callback, tokenSwapURL, tokenRefreshURL, and scopes in your app.config.js/app.json.'
    );
  }

  validateSpotifyConfig(props);

  // Apply iOS configurations
  config = withSpotifyConfiguration(config, props);
  config = withSpotifyURLSchemes(config, props);

  // Apply Android configurations
  config = withSpotifyAndroidManifest(config, props);

  return config;
};

export default createRunOncePlugin(withSpotifyAuth, pkg.name, pkg.version);
