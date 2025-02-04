import { type ConfigPlugin, createRunOncePlugin, WarningAggregator } from '@expo/config-plugins'
import { type ExpoConfig } from '@expo/config-types'

import { withSpotifyQueryScheme } from './ios/withSpotifyQueryScheme'
import { withSpotifyURLScheme } from './ios/withSpotifyURLScheme'
import { SpotifyConfig } from './types'
import withSpotifyOAuthConfig from './withSpotifyConfig'

const pkg: {
  name: string;
  version: string;
  // eslint-disable-next-line @typescript-eslint/no-var-requires
} = require('../../package.json');

function ensureDevClientInstalled(config: any) {
  const devClient = config.plugins?.find((plugin: any) => 
    typeof plugin === 'string' ? plugin === 'expo-dev-client' : plugin[0] === 'expo-dev-client'
  );

  if (!devClient) {
    WarningAggregator.addWarningIOS(
      'spotify-auth',
      'This module requires expo-dev-client to be installed. Please run: npx expo install expo-dev-client'
    );
  }
}

const withSpotifyAuth: ConfigPlugin<SpotifyConfig> = (config, props) => {
  ensureDevClientInstalled(config);
  
  let modifiedConfig = withSpotifyOAuthConfig(config as ExpoConfig, props) as any;

  // iOS specific
  modifiedConfig = withSpotifyQueryScheme(modifiedConfig, props);
  modifiedConfig = withSpotifyURLScheme(modifiedConfig, props);

  return modifiedConfig;
}

export default createRunOncePlugin(withSpotifyAuth, pkg.name, pkg.version);
