import { ConfigPlugin, withInfoPlist } from '@expo/config-plugins';
import { SpotifyConfig } from './types';

export const withPreBuildConfig: ConfigPlugin<SpotifyConfig> = (config, props) => {
  return withInfoPlist(config, (config) => {
    // Set minimum iOS version in Info.plist
    config.modResults.MinimumOSVersion = '13.0';
    
    // Add build-related keys
    config.modResults.EnableBitcode = false;
    config.modResults.SwiftVersion = '5.4';
    config.modResults.IphoneosDeploymentTarget = '13.0';
    
    return config;
  });
}; 