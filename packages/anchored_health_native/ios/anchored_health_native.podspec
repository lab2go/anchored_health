#
# CocoaPods spec. Swift Package Manager builds use
# anchored_health_native/Package.swift with the same sources.
#
Pod::Spec.new do |s|
  s.name             = 'anchored_health_native'
  s.version          = '0.1.0'
  s.summary          = 'HealthKit bridge (Pigeon).'
  s.description      = <<-DESC
Authorization, anchored queries with deletions, sample model, blood pressure
correlation, writing with sync metadata and deleting via HealthKit.
                       DESC
  s.homepage         = 'https://example.com/anchored_health'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'anchored_health contributors' => 'maintainers@anchored-health.invalid' }
  s.source           = { :path => '.' }
  s.source_files = 'anchored_health_native/Sources/anchored_health_native/**/*.swift'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'
  s.frameworks = 'HealthKit'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
  s.resource_bundles = {'anchored_health_native_privacy' => ['anchored_health_native/Sources/anchored_health_native/PrivacyInfo.xcprivacy']}
end
