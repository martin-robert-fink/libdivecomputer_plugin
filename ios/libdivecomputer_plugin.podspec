Pod::Spec.new do |s|
  s.name             = 'libdivecomputer_plugin'
  s.version          = '0.0.1'
  s.summary          = 'Flutter plugin wrapping libdivecomputer.'
  s.description      = <<-DESC
A Flutter plugin that provides native communication with dive computers
using the libdivecomputer library. Uses CoreBluetooth for BLE transport
on iOS.
                       DESC
  s.homepage         = 'https://github.com/martin-robert-fink/libdivecomputer_plugin'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Name' => 'your@email.com' }
  s.source           = { :path => '.' }

  s.source_files     = 'Classes/**/*.{swift,h,c}'

  s.vendored_frameworks = 'Frameworks/libdivecomputer.xcframework'

s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'GCC_WARN_INHIBIT_ALL_WARNINGS' => 'YES',
}
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'
  s.frameworks       = ['CoreBluetooth', 'Foundation']

  s.resource_bundles = {'libdivecomputer_plugin_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end