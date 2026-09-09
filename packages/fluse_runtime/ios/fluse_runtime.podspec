#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint fluse_runtime.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'fluse_runtime'
  # pubspec.yaml の version と揃える。
  s.version          = '0.1.0'
  s.summary          = 'fluse の端末側ランタイム（iOS）'
  s.description      = <<-DESC
ユーザープロジェクトの dev_dependencies に入る端末側ランタイム。
接続・トンネル・エラー表示を担う。release ビルドには含まれない。
                       DESC
  s.homepage         = 'https://github.com/goofmint/fluse'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'goofmint' => 'https://github.com/goofmint' }
  s.source           = { :path => '.' }
  # テスト（ios/Tests/）は含めない。SwiftPM 側だけが読む。
  s.source_files     = 'Classes/**/*'
  # 外部 Pod は入れない。Android の OkHttp / CameraX / ZXing /
  # security-crypto に相当するものは、iOS では OS 標準 API で足りる。
  s.dependency 'Flutter'
  # Flutter ツールが生成する podspec テンプレートの値に揃える
  # （`flutter/packages/flutter_tools/templates/plugin/ios.tmpl/projectName.podspec.tmpl`）。
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
