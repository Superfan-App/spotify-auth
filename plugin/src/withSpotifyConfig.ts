import { ConfigPlugin, withInfoPlist } from 'expo/config-plugins'

import { ISpotifyConfig } from './types'

const withSpotifyConfigIOS: ConfigPlugin<ISpotifyConfig> = (config, spotifyConfig) => {
  return withInfoPlist(config, (config) => {
    Object.entries(spotifyConfig).forEach(([key, value]) => {
      config.modResults[key] = value
    })

    return config
  })
}

export const withSpotifyConfig: ConfigPlugin<ISpotifyConfig> = (config, spotifyConfig) => {
  config = withSpotifyConfigIOS(config, spotifyConfig)

  return config
}