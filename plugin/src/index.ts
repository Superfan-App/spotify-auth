import { type ConfigPlugin, createRunOncePlugin } from '@expo/config-plugins'

import { withSpotifyQueryScheme } from './ios/withSpotifyQueryScheme'
import { withSpotifyURLScheme } from './ios/withSpotifyURLScheme'
import { SpotifyConfig } from './types'
import { withSpotifyOAuthConfig } from './withSpotifyConfig'

import pkg from '../../package.json'

const withSpotifyAuth: ConfigPlugin<SpotifyConfig> = (config, props) => {
  config = withSpotifyOAuthConfig(config, props)

  // iOS specific
  config = withSpotifyQueryScheme(config, props)
  config = withSpotifyURLScheme(config, props)

  return config
}

export default createRunOncePlugin(withSpotifyAuth, pkg.name, pkg.version);
