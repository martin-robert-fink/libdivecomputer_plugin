Pod::Spec.new do |s|
  s.name             = 'dive_computer'
  s.version          = '0.0.1'
  s.summary          = 'Flutter plugin wrapping libdivecomputer.'
  s.description      = <<-DESC
A Flutter plugin that provides native communication with dive computers
using the libdivecomputer library. Uses CoreBluetooth for BLE transport
on macOS.
                       DESC
  s.homepage         = 'https://github.com/martin-robert-fink/dive_computer'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Name' => 'your@email.com' }
  s.source           = { :path => '.' }

  s.source_files     = 'Classes/**/*.{swift,h,c}'

  s.vendored_frameworks = 'Frameworks/libdivecomputer.xcframework'

  # Preserve the module map so CocoaPods doesn't strip it
  s.preserve_paths = 'Frameworks/module.modulemap'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    # Point Swift at the module map instead of a bridging header
    'SWIFT_INCLUDE_PATHS' => '$(PODS_TARGET_SRCROOT)/Frameworks',
    # Ensure the xcframework headers are findable by the module map
    'HEADER_SEARCH_PATHS' =>
      '$(PODS_TARGET_SRCROOT)/Frameworks/libdivecomputer.xcframework/macos-*/**/Headers',
    'GCC_WARN_INHIBIT_ALL_WARNINGS' => 'YES',
  }

  s.platform              = :osx, '10.15'
  s.osx.deployment_target = '10.15'
  s.frameworks            = ['CoreBluetooth', 'Foundation']
  s.dependency              'FlutterMacOS'
  s.swift_version          = '5.0'
end