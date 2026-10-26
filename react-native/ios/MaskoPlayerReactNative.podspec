require 'fileutils'
require 'json'
require 'pathname'

package = JSON.parse(File.read(File.join(__dir__, '..', 'package.json')))

# The Swift player (apple/Sources/MaskoPlayer), the engine
# (apple/MaskoPlayerFFI.xcframework) and the AV1 decoder dav1d
# (apple/dav1d.xcframework) build into this pod from vendor/. In the
# masko-player repository, vendor/ links to apple/'s Swift files, so the pod
# always builds the current sources, and the engine and dav1d are merged into
# one library there (scripts/ios-libraries.mjs); `npm pack` puts copies there
# instead (scripts/vendor.mjs). CocoaPods does not follow a linked folder, so
# each Swift file gets its own link.
apple = File.expand_path('../../apple', __dir__)
vendor = File.join(__dir__, 'vendor')
if File.exist?(File.join(apple, 'Sources', 'MaskoPlayer', 'MaskoPlayer.swift'))
  link = lambda do |target, at|
    FileUtils.mkdir_p(File.dirname(at))
    File.symlink(Pathname.new(target).relative_path_from(Pathname.new(File.dirname(at))).to_s, at)
  end
  FileUtils.rm_rf(vendor)
  sources = File.join(apple, 'Sources', 'MaskoPlayer')
  Dir.glob(File.join(sources, '**', '*.swift')).sort.each do |file|
    link.call(file, File.join(vendor, 'MaskoPlayer', Pathname.new(file).relative_path_from(Pathname.new(sources)).to_s))
  end
  link.call(File.join(sources, 'PrivacyInfo.xcprivacy'), File.join(vendor, 'MaskoPlayer', 'PrivacyInfo.xcprivacy'))
  unless system('node', File.join(__dir__, '..', 'scripts', 'ios-libraries.mjs'), vendor)
    raise 'The engine and dav1d could not be merged: run scripts/build-apple.sh and scripts/build-dav1d-apple.sh in the masko-player repository.'
  end
end

Pod::Spec.new do |s|
  s.name           = 'MaskoPlayerReactNative'
  s.version        = package['version']
  s.summary        = package['description']
  s.description    = package['description']
  s.license        = package['license']
  s.author         = 'Masko'
  s.homepage       = 'https://masko.ai'
  s.platforms      = { :ios => '15.1' }
  s.swift_version  = '5.9'
  s.source         = { git: '' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES'
  }

  s.source_files = '*.swift', 'vendor/MaskoPlayer/**/*.swift'
  s.vendored_frameworks = 'vendor/MaskoPlayerFFI.xcframework'
  # The player reads system uptime, a required-reason API for the App Store.
  s.resource_bundles = { 'MaskoPlayerPrivacy' => ['vendor/MaskoPlayer/PrivacyInfo.xcprivacy'] }
  s.frameworks = 'AVFoundation', 'QuartzCore', 'Metal', 'VideoToolbox'
end
