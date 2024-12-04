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
  s.platforms      = :ios, '13.0'
  s.swift_version  = '5.4'
  s.source         = { git: 'https://github.com/william-matz/spotify-auth' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'

  # Swift/Objective-C compatibility
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_COMPILATION_MODE' => 'wholemodule'
  }

  s.source_files = "**/*.{h,m,swift}"
  s.exclude_files = ["Frameworks/SpotifyiOS.xcframework/**/*.h"]
  s.vendored_frameworks = 'Frameworks/SpotifyiOS.xcframework'
  s.preserve_paths = [
    'Frameworks/*.xcframework',
  ]
end
