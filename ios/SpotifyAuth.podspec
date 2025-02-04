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
  
  # Minimum iOS version requirement and Swift version
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.4'
  
  # Define your source. It’s best to specify a tag to ensure the right version is fetched.
  s.source           = { 
    git: 'https://github.com/superfan-app/spotify-auth.git',
    tag: package['version']
  }
  
  # Mark the module as a static framework.
  s.static_framework = true
  
  # Declare dependency on ExpoModulesCore
  s.dependency 'ExpoModulesCore'
  
  # Pod target build settings. Vendored frameworks automatically set up module maps,
  # so explicit FRAMEWORK_SEARCH_PATHS are often unnecessary.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE'            => 'YES',
    'SWIFT_COMPILATION_MODE'    => 'wholemodule',
    'ENABLE_BITCODE'            => 'NO',
    'IPHONEOS_DEPLOYMENT_TARGET' => '13.0'
  }
  
  s.user_target_xcconfig = {
    'ENABLE_BITCODE'            => 'NO',
    'IPHONEOS_DEPLOYMENT_TARGET' => '13.0'
  }
  
  # Include all Swift files in the same directory as the podspec.
  s.source_files = "*.swift"
  
  # Specify the vendored framework (Spotify's iOS SDK).
  s.vendored_frameworks = 'Frameworks/SpotifyiOS.xcframework'
  
  # Preserve the vendored framework directory.
  s.preserve_paths = ['Frameworks/*.xcframework']
  
  # Note: If you need to adjust build settings via post-install hooks,
  # it's recommended to do so in your Podfile.
end
