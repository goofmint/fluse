/// Preview App に組み込まれる端末側ランタイム。
///
/// Dart 側は `flusePreviewMain()` でユーザーの `main()` をラップし、
/// VM Service の URI を Kotlin 側へ通知する。Kotlin 側の常駐実装
/// （接続・トンネル・エラーオーバーレイ）は Flutter プラグイン化とあわせて
/// Task 4.1 以降で追加する。
library;
