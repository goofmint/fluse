/// 外部プロセス呼び出しの抽象。
///
/// `flutter` / `adb` / `keytool` / `frontend_server` は全てこの抽象越しに
/// 起動する（設計 §7.1）。テストでは `FakeProcessManager` に差し替える。
///
/// 抽象そのものは `package:process` のものを使う。flutter_tools が同じ
/// パッケージを使っており、`start` / `run` / `runSync` / `canRun` /
/// `killPid` が揃っているため、独自に定義し直す理由が無い。
library;

export 'package:process/process.dart' show LocalProcessManager, ProcessManager;
