const { withPlugins } = require('@expo/config-plugins');
const withSpotifyConfig = require('./plugin/build/withSpotifyConfig').default;

module.exports = (config) => {
  return withPlugins(config, [withSpotifyConfig]);
};