# ios/SpotifyAuth.podspec

require 'json'

# Assumes package.json is one level up from the ios/ directory
package = JSON.parse(File.read(File.join(__dir__, '..', 'package.json')))

Pod::Spec.new do |s|
  s.name             = 'SpotifyAuth'
  s.version          = package['version']
  s.summary          = package['description']
  s.description      = package['description']
  s.license          = package['license']
  s.author           = package['author']
  s.homepage         = package['homepage']
  s.platform         = :ios, '15.1'
  s.swift_version    = '5.9'
  
  s.source           = { 
    git: 'https://github.com/superfan-app/spotify-auth.git',
    tag: package['version']
  }
  
  s.static_framework = true
  
  s.dependency 'ExpoModulesCore'
  s.dependency 'KeychainAccess', '~> 4.2'
  
  # Pod target build settings
  s.pod_target_xcconfig = {
    'DEFINES_MODULE'            => 'YES',
    'SWIFT_COMPILATION_MODE'    => 'wholemodule',
    'ENABLE_BITCODE'            => 'NO',
    'IPHONEOS_DEPLOYMENT_TARGET' => '15.1'
  }
  
  s.user_target_xcconfig = {
    'ENABLE_BITCODE'            => 'NO',
    'IPHONEOS_DEPLOYMENT_TARGET' => '15.1',
    'OTHER_LDFLAGS'            => '-ObjC'
  }
  
  # Include all source files and public headers
  s.source_files = "*.{swift,h,m}"
  s.public_header_files = "SpotifyAuthHeaders.h"
  
  # Specify the vendored framework (Spotify's iOS SDK).
  s.vendored_frameworks = 'Frameworks/SpotifyiOS.xcframework'
  
  # Preserve the vendored framework directory.
  s.preserve_paths = ['Frameworks/*.xcframework']
  
  # Note: If you need to adjust build settings via post-install hooks,
  # it's recommended to do so in your Podfile.
end
