/// ソース変更から画面反映までの全工程を担う開発PC側サーバ。
///
/// frontend_server の駆動、DevFS への差分転送、VM Service の
/// reloadSources 呼び出し、端末との WebSocket / トンネル中継を含む。
/// 実装は Task 0.3 以降で追加する。
library;
