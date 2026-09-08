/// 解析の対象プラットフォーム（Task 10.5）。
///
/// `fluse` はまず Android だけに対応していた。ここに iOS を足すが、
/// **既定は `android` のまま**にする。呼び出し側が明示しない限り、
/// 従来どおりの挙動（`android/app/build.gradle(.kts)` を読む）を保つ。
enum ProjectPlatform {
  /// Android。`android/app/build.gradle(.kts)` の `applicationId` を読む。
  android,

  /// iOS。`ios/Runner.xcodeproj/project.pbxproj` などの `bundleId` を読む。
  ios,
}
