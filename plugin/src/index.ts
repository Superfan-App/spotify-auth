import { ConfigPlugin } from '@expo/config-plugins'

import { withSpotifyQueryScheme } from './ios/withSpotifyQueryScheme'
import { withSpotifyURLScheme } from './ios/withSpotifyURLScheme'
import { ISpotifyConfig } from './types'
import { withSpotifyConfig } from './withSpotifyConfig'

const withSpotifyRemote: ConfigPlugin<ISpotifyConfig> = (config, props) => {
  config = withSpotifyConfig(config, props)

  // iOS specific
  config = withSpotifyQueryScheme(config, props)
  config = withSpotifyURLScheme(config, props)

  return config
}

export default withSpotifyRemote