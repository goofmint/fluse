/// fluse のサーバとランタイムが共有する唯一の通信契約。
///
/// 制御メッセージ（WebSocket text frame / JSON）とトンネルフレーム
/// （WebSocket binary frame）の定義および符号化を提供する。
///
/// **Kotlin 側は同じ仕様を手書きで実装する**（設計 §2.2.1）。
/// ここを変更したら Kotlin 側も必ず追従させること。
library;

export 'src/build_meta.dart';
export 'src/build_meta_parser.dart';
export 'src/diagnostic_entry.dart';
export 'src/fluse_message.dart';
export 'src/mask.dart';
export 'src/message_codes.dart';
export 'src/protocol_exception.dart';
export 'src/protocol_version.dart';
export 'src/tunnel_frame.dart';
