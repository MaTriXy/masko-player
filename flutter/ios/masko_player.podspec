require 'yaml'

# masko_player for apps that build their Flutter plugins with CocoaPods. The
# Swift player (masko_player/vendor/MaskoPlayer) builds into this pod with the
# plugin, and the engine with dav1d is one prebuilt library
# (masko_player/vendor/MaskoPlayerFFI.xcframework): the copies
# scripts/build-flutter.sh makes, which masko_player/Package.swift also takes.
pubspec = YAML.load_file(File.join(__dir__, '..', 'pubspec.yaml'))
vendor = File.join(__dir__, 'masko_player', 'vendor')
unless File.exist?(File.join(vendor, 'MaskoPlayerFFI.xcframework', 'Info.plist'))
  raise 'The Swift player is missing: run scripts/build-flutter.sh in the masko-player repository.'
end

Pod::Spec.new do |s|
  s.name           = 'masko_player'
  s.version        = pubspec['version']
  s.summary        = 'Plays Masko mascots in Flutter apps.'
  s.description    = pubspec['description']
  s.license        = 'MIT'
  s.author         = 'Masko'
  s.homepage       = 'https://masko.ai/docs/player'
  s.source         = { :path => '.' }
  s.platform       = :ios, '15.0'
  s.swift_version  = '5.9'

  s.dependency 'Flutter'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }

  s.source_files = 'masko_player/Sources/masko_player/**/*.swift', 'masko_player/vendor/MaskoPlayer/**/*.swift'
  s.vendored_frameworks = 'masko_player/vendor/MaskoPlayerFFI.xcframework'
  # The player reads system uptime, a required-reason API for the App Store.
  s.resource_bundles = { 'MaskoPlayerPrivacy' => ['masko_player/vendor/MaskoPlayer/PrivacyInfo.xcprivacy'] }
  s.frameworks = 'AVFoundation', 'QuartzCore', 'Metal', 'VideoToolbox'
end
