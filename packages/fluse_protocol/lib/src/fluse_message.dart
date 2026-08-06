import 'diagnostic_entry.dart';
import 'json_reader.dart';
import 'message_codes.dart';
import 'protocol_exception.dart';

/// サーバとランタイムが交わす制御メッセージ（設計 §2.2.1）。
///
/// WebSocket の text frame に JSON として載る。バイナリ frame は
/// トンネル（`TunnelFrame`）が使う。
///
/// **Kotlin 側は同じ仕様を手書きで実装する。** メッセージ数が20未満で、
/// コード生成器の保守コストが上回るため（設計 §2.2.1）。ここを変えたら
/// Kotlin 側も必ず追従させること。
sealed class FluseMessage {
  const FluseMessage();

  /// JSON の `type` フィールドに載る値。
  String get type;

  Map<String, Object?> toJson();

  /// `type` を見て対応するメッセージに振り分ける。
  ///
  /// 未知の `type` は [FluseProtocolException] で明示的に失敗させる。
  /// 黙って無視すると、送った側は届いたと思い込んだまま応答を待ち続ける。
  static FluseMessage fromJson(Map<String, Object?> json) {
    final Object? rawType = json['type'];
    if (rawType == null) {
      throw const FluseProtocolException('メッセージに type がありません');
    }
    if (rawType is! String) {
      throw FluseProtocolException.wrongType(
        'FluseMessage',
        'type',
        '文字列',
        rawType,
      );
    }

    return switch (rawType) {
      HelloMessage.messageType => HelloMessage.fromJson(json),
      VmServiceReadyMessage.messageType => VmServiceReadyMessage.fromJson(json),
      ReadyMessage.messageType => const ReadyMessage(),
      LogMessage.messageType => LogMessage.fromJson(json),
      ErrorMessage.messageType => ErrorMessage.fromJson(json),
      AcceptMessage.messageType => AcceptMessage.fromJson(json),
      RejectMessage.messageType => RejectMessage.fromJson(json),
      ReloadMessage.messageType => const ReloadMessage(),
      CompileErrorMessage.messageType => CompileErrorMessage.fromJson(json),
      CompileOkMessage.messageType => const CompileOkMessage(),
      PingMessage.messageType => PingMessage.fromJson(json),
      PongMessage.messageType => PongMessage.fromJson(json),
      CloseMessage.messageType => CloseMessage.fromJson(json),
      _ => throw FluseProtocolException('未知の type: $rawType'),
    };
  }
}

// --------------------------------------------------------- Client -> Server

/// 接続時の名乗り（type: `hello`）。
final class HelloMessage extends FluseMessage {
  const HelloMessage({
    required this.protocolVersion,
    required this.projectId,
    required this.flutterRevision,
    required this.dartVersion,
    required this.appVersion,
    required this.deviceId,
    required this.deviceName,
    this.pairingToken,
    this.deviceToken,
  });

  static const String messageType = 'hello';

  final int protocolVersion;

  /// `pubspec.yaml` の name + プロジェクト絶対パスの sha256 先頭16桁
  /// （設計 §4.2(a)）。
  final String projectId;

  final String flutterRevision;
  final String dartVersion;

  /// init 時に埋め込まれたビルドID。
  final String appVersion;

  /// ANDROID_ID 由来のハッシュ。
  final String deviceId;

  final String deviceName;

  /// 初回ペアリング時のみ。
  final String? pairingToken;

  /// ペアリング済みの場合。
  final String? deviceToken;

  @override
  String get type => messageType;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'protocolVersion': protocolVersion,
    'projectId': projectId,
    'flutterRevision': flutterRevision,
    'dartVersion': dartVersion,
    'appVersion': appVersion,
    'deviceId': deviceId,
    'deviceName': deviceName,
    if (pairingToken != null) 'pairingToken': pairingToken,
    if (deviceToken != null) 'deviceToken': deviceToken,
  };

  static HelloMessage fromJson(Map<String, Object?> json) {
    final JsonReader reader = JsonReader(json);
    return HelloMessage(
      protocolVersion: reader.requireInt(messageType, 'protocolVersion'),
      projectId: reader.requireString(messageType, 'projectId'),
      flutterRevision: reader.requireString(messageType, 'flutterRevision'),
      dartVersion: reader.requireString(messageType, 'dartVersion'),
      appVersion: reader.requireString(messageType, 'appVersion'),
      deviceId: reader.requireString(messageType, 'deviceId'),
      deviceName: reader.requireString(messageType, 'deviceName'),
      pairingToken: reader.optionalString(messageType, 'pairingToken'),
      deviceToken: reader.optionalString(messageType, 'deviceToken'),
    );
  }

  /// **トークンは含めない。** ログや例外文に混ざると漏れる。
  @override
  String toString() =>
      'HelloMessage(v$protocolVersion, project: $projectId, '
      'device: $deviceName)';
}

/// VM Service が立ち上がったことの通知（type: `vmServiceReady`）。
final class VmServiceReadyMessage extends FluseMessage {
  const VmServiceReadyMessage({required this.vmServiceUri});

  static const String messageType = 'vmServiceReady';

  /// `http://127.0.0.1:PORT/AUTHCODE/` 形式。
  ///
  /// **パスセグメントの認証コードが資格情報**なので、ログに出す際は
  /// 必ずマスクすること（`fluse_server` の `redactVmServiceUri`）。
  final String vmServiceUri;

  @override
  String get type => messageType;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'vmServiceUri': vmServiceUri,
  };

  static VmServiceReadyMessage fromJson(Map<String, Object?> json) =>
      VmServiceReadyMessage(
        vmServiceUri: JsonReader(
          json,
        ).requireString(messageType, 'vmServiceUri'),
      );

  /// URI は載せない。認証コードが含まれるため。
  @override
  String toString() => 'VmServiceReadyMessage(...)';
}

/// 準備完了（type: `ready`）。
final class ReadyMessage extends FluseMessage {
  const ReadyMessage();

  static const String messageType = 'ready';

  @override
  String get type => messageType;

  @override
  Map<String, Object?> toJson() => <String, Object?>{'type': type};

  @override
  String toString() => 'ReadyMessage()';
}

/// 端末からのログ（type: `log`）。
final class LogMessage extends FluseMessage {
  const LogMessage({required this.level, required this.message});

  static const String messageType = 'log';

  /// `debug` / `info` / `warn` / `error`。既知の語彙は [LogLevel] を参照。
  final String level;

  final String message;

  @override
  String get type => messageType;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'level': level,
    'message': message,
  };

  static LogMessage fromJson(Map<String, Object?> json) {
    final JsonReader reader = JsonReader(json);
    return LogMessage(
      level: reader.requireString(messageType, 'level'),
      message: reader.requireString(messageType, 'message'),
    );
  }

  @override
  String toString() => 'LogMessage($level)';
}

/// 端末からのエラー通知（type: `error`）。
final class ErrorMessage extends FluseMessage {
  const ErrorMessage({required this.code, required this.message, this.detail});

  static const String messageType = 'error';

  /// 設計 §5.1 の分類。既知の値は [FluseErrorCode] を参照。
  ///
  /// **文字列のまま持つ。** 新しいコードを受け取っても解析を失敗させず、
  /// `message` だけでも表示できるようにするため。
  final String code;

  final String message;
  final String? detail;

  @override
  String get type => messageType;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'code': code,
    'message': message,
    if (detail != null) 'detail': detail,
  };

  static ErrorMessage fromJson(Map<String, Object?> json) {
    final JsonReader reader = JsonReader(json);
    return ErrorMessage(
      code: reader.requireString(messageType, 'code'),
      message: reader.requireString(messageType, 'message'),
      detail: reader.optionalString(messageType, 'detail'),
    );
  }

  @override
  String toString() => 'ErrorMessage($code)';
}

// --------------------------------------------------------- Server -> Client

/// 接続を受理した（type: `accept`）。
final class AcceptMessage extends FluseMessage {
  const AcceptMessage({
    required this.sessionId,
    required this.heartbeatIntervalMs,
    this.issuedDeviceToken,
  });

  static const String messageType = 'accept';

  final String sessionId;

  /// ペアリング成立時に発行される。
  final String? issuedDeviceToken;

  /// `ping` を送る間隔。
  final int heartbeatIntervalMs;

  @override
  String get type => messageType;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'sessionId': sessionId,
    'heartbeatIntervalMs': heartbeatIntervalMs,
    if (issuedDeviceToken != null) 'issuedDeviceToken': issuedDeviceToken,
  };

  static AcceptMessage fromJson(Map<String, Object?> json) {
    final JsonReader reader = JsonReader(json);
    return AcceptMessage(
      sessionId: reader.requireString(messageType, 'sessionId'),
      heartbeatIntervalMs: reader.requireInt(
        messageType,
        'heartbeatIntervalMs',
      ),
      issuedDeviceToken: reader.optionalString(
        messageType,
        'issuedDeviceToken',
      ),
    );
  }

  /// 発行トークンは載せない。
  @override
  String toString() => 'AcceptMessage($sessionId)';
}

/// 接続を拒否した（type: `reject`）。
final class RejectMessage extends FluseMessage {
  const RejectMessage({required this.code, required this.message});

  /// 既知のコードから作る。
  RejectMessage.of(RejectCode code, this.message) : code = code.wireValue;

  static const String messageType = 'reject';

  /// 拒否理由。既知の値は [RejectCode] を参照。
  ///
  /// **文字列のまま持つ。** 新しいサーバが増やしたコードを古いアプリが
  /// 受け取ったときに、理由の文言すら表示できなくなるのを避けるため。
  final String code;

  final String message;

  /// 既知のコードなら対応する定数、そうでなければ null。
  RejectCode? get knownCode => RejectCode.tryParse(code);

  @override
  String get type => messageType;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'code': code,
    'message': message,
  };

  static RejectMessage fromJson(Map<String, Object?> json) {
    final JsonReader reader = JsonReader(json);
    return RejectMessage(
      code: reader.requireString(messageType, 'code'),
      message: reader.requireString(messageType, 'message'),
    );
  }

  @override
  String toString() => 'RejectMessage($code)';
}

/// リロードの進捗通知（type: `reload`）。
final class ReloadMessage extends FluseMessage {
  const ReloadMessage();

  static const String messageType = 'reload';

  @override
  String get type => messageType;

  @override
  Map<String, Object?> toJson() => <String, Object?>{'type': type};

  @override
  String toString() => 'ReloadMessage()';
}

/// コンパイルエラー（type: `compileError`）。
final class CompileErrorMessage extends FluseMessage {
  const CompileErrorMessage({required this.summary, required this.diagnostics});

  static const String messageType = 'compileError';

  /// 1行サマリ。
  final String summary;

  final List<DiagnosticEntry> diagnostics;

  @override
  String get type => messageType;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'summary': summary,
    'diagnostics': <Map<String, Object?>>[
      for (final DiagnosticEntry entry in diagnostics) entry.toJson(),
    ],
  };

  static CompileErrorMessage fromJson(Map<String, Object?> json) {
    final JsonReader reader = JsonReader(json);
    return CompileErrorMessage(
      summary: reader.requireString(messageType, 'summary'),
      diagnostics: <DiagnosticEntry>[
        for (final Object? entry in reader.requireList(
          messageType,
          'diagnostics',
        ))
          DiagnosticEntry.fromJson(
            JsonReader.requireObject(messageType, 'diagnostics', entry),
          ),
      ],
    );
  }

  @override
  String toString() => 'CompileErrorMessage(${diagnostics.length}件)';
}

/// コンパイルが通った（type: `compileOk`）。オーバーレイの解除に使う。
final class CompileOkMessage extends FluseMessage {
  const CompileOkMessage();

  static const String messageType = 'compileOk';

  @override
  String get type => messageType;

  @override
  Map<String, Object?> toJson() => <String, Object?>{'type': type};

  @override
  String toString() => 'CompileOkMessage()';
}

// -------------------------------------------------------------------- 双方向

/// 疎通確認（type: `ping`）。
final class PingMessage extends FluseMessage {
  const PingMessage({required this.seq, required this.timestampMs});

  static const String messageType = 'ping';

  /// 対応する `pong` と突き合わせる。
  final int seq;

  /// 送信側の時刻。RTT 計測に使う。
  final int timestampMs;

  @override
  String get type => messageType;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'seq': seq,
    'timestampMs': timestampMs,
  };

  static PingMessage fromJson(Map<String, Object?> json) {
    final JsonReader reader = JsonReader(json);
    return PingMessage(
      seq: reader.requireInt(messageType, 'seq'),
      timestampMs: reader.requireInt(messageType, 'timestampMs'),
    );
  }

  /// この ping に対応する pong を作る。
  ///
  /// **受け取った値をそのまま返す。** 受信側で時刻を作り直すと
  /// RTT が測れなくなる。
  PongMessage toPong() => PongMessage(seq: seq, timestampMs: timestampMs);

  @override
  String toString() => 'PingMessage($seq)';
}

/// 疎通確認への応答（type: `pong`）。
final class PongMessage extends FluseMessage {
  const PongMessage({required this.seq, required this.timestampMs});

  static const String messageType = 'pong';

  final int seq;
  final int timestampMs;

  @override
  String get type => messageType;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'seq': seq,
    'timestampMs': timestampMs,
  };

  static PongMessage fromJson(Map<String, Object?> json) {
    final JsonReader reader = JsonReader(json);
    return PongMessage(
      seq: reader.requireInt(messageType, 'seq'),
      timestampMs: reader.requireInt(messageType, 'timestampMs'),
    );
  }

  @override
  String toString() => 'PongMessage($seq)';
}

/// 正常終了の通知（type: `close`）。
///
/// 異常終了は WebSocket の close フレームに委ねる。
final class CloseMessage extends FluseMessage {
  const CloseMessage({required this.code, this.message});

  /// 既知のコードから作る。
  CloseMessage.of(CloseCode code, {this.message}) : code = code.wireValue;

  static const String messageType = 'close';

  /// 終了理由。既知の値は [CloseCode] を参照。
  final String code;

  final String? message;

  /// 既知のコードなら対応する定数、そうでなければ null。
  CloseCode? get knownCode => CloseCode.tryParse(code);

  @override
  String get type => messageType;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'type': type,
    'code': code,
    if (message != null) 'message': message,
  };

  static CloseMessage fromJson(Map<String, Object?> json) {
    final JsonReader reader = JsonReader(json);
    return CloseMessage(
      code: reader.requireString(messageType, 'code'),
      message: reader.optionalString(messageType, 'message'),
    );
  }

  @override
  String toString() => 'CloseMessage($code)';
}
