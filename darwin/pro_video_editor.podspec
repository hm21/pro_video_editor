#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint pro_video_editor.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'pro_video_editor'
  s.version          = '0.0.1'
  s.summary          = 'A new Flutter plugin project.'
  s.description      = <<-DESC
A Flutter plugin which adds support for video editing.
                       DESC
  s.homepage         = 'https://waio.ch'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'WAIO Frei Applications' => 'info@waio.ch' }
  s.source           = { :path => '.' }
  s.source_files     = 'pro_video_editor/Sources/pro_video_editor/**/*'
  s.swift_version    = '5.0'
  s.osx.frameworks   = 'FlutterMacOS'

  s.ios.deployment_target = '13.0'
  s.ios.dependency 'Flutter'
  s.ios.pod_target_xcconfig = { 
    'DEFINES_MODULE' => 'YES', 
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' 
  }

  s.osx.deployment_target = '10.15'
  s.osx.dependency 'FlutterMacOS'
  s.osx.pod_target_xcconfig = { 
    'DEFINES_MODULE' => 'YES' 
  }

  # s.ios.resource_bundles = {'pro_video_editor_ios_privacy' => ['pro_video_editor/Sources/Resources/PrivacyInfo.xcprivacy']}
  # s.osx.resource_bundles = {'pro_video_editor_osx_privacy' => ['pro_video_editor/Sources/Resources/PrivacyInfo.xcprivacy']}
end