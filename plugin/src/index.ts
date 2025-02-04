import { type ConfigPlugin, createRunOncePlugin, WarningAggregator } from '@expo/config-plugins'

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
  
  config = withSpotifyOAuthConfig(config, props)

  // iOS specific
  config = withSpotifyQueryScheme(config, props)
  config = withSpotifyURLScheme(config, props)

  return config
}

export default createRunOncePlugin(withSpotifyAuth, pkg.name, pkg.version);
