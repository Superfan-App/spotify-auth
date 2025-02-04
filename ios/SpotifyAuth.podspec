require 'json'

package = JSON.parse(File.read(File.join(__dir__, '..', 'package.json')))

Pod::Spec.new do |s|
  s.name           = 'SpotifyAuth'
  s.version        = package['version']
  s.summary        = package['description']
  s.description    = package['description']
  s.license        = package['license']
  s.author         = package['author']
  s.homepage       = package['homepage']
  s.platforms      = { :ios => '13.0' }  # Updated minimum iOS version
  s.swift_version  = '5.4'
  s.source         = { git: 'https://github.com/superfan-app/spotify-auth' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'

  # Swift/Objective-C compatibility
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_COMPILATION_MODE' => 'wholemodule',
    'FRAMEWORK_SEARCH_PATHS' => '"$(PODS_ROOT)/../../node_modules/@superfan-app/spotify-auth/ios/Frameworks"',
    'HEADER_SEARCH_PATHS' => '"$(PODS_ROOT)/../../node_modules/@superfan-app/spotify-auth/ios/Frameworks/SpotifyiOS.xcframework/ios-arm64/SpotifyiOS.framework/Headers"',
    'ENABLE_BITCODE' => 'NO',
    'IPHONEOS_DEPLOYMENT_TARGET' => '13.0',
    'SWIFT_VERSION' => '5.4'
  }

  s.user_target_xcconfig = {
    'ENABLE_BITCODE' => 'NO',
    'IPHONEOS_DEPLOYMENT_TARGET' => '13.0'
  }

  s.source_files = "**/*.{h,m,swift}"
  s.vendored_frameworks = 'Frameworks/SpotifyiOS.xcframework'
  s.preserve_paths = [
    'Frameworks/*.xcframework',
  ]

  # Post install hooks
  def s.post_install(target)
    target.build_configurations.each do |config|
      config.build_settings['ENABLE_BITCODE'] = 'NO'
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '13.0'
    end
  end
end
