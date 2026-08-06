/// `reject` の理由（設計 §2.2.1 / §5.1）。
enum RejectCode {
  /// トークン不一致 / TTL切れ。
  authFailed('AUTH_FAILED'),

  /// 別プロジェクトの Preview App。
  projectMismatch('PROJECT_MISMATCH'),

  /// Flutter SDK のリビジョン不一致。
  revisionMismatch('REVISION_MISMATCH'),

  /// プロトコルバージョン不一致。
  protocolMismatch('PROTOCOL_MISMATCH'),

  /// 指紋差分により Preview App が古い。
  appOutdated('APP_OUTDATED'),

  /// Phase1 は1台のみ。2台目は受け付けない（設計 §10-10）。
  tooManyDevices('TOO_MANY_DEVICES');

  const RejectCode(this.wireValue);

  /// JSON に載る文字列。
  final String wireValue;

  /// 既知の値なら対応する定数、そうでなければ null。
  ///
  /// **未知の値でも解析は失敗させない。** 新しいサーバが増やしたコードを
  /// 古いアプリが受け取ったときに、理由の文言すら表示できなくなるのを
  /// 避けるため。呼び出し側は `message` を表示できる。
  static RejectCode? tryParse(String value) {
    for (final RejectCode code in values) {
      if (code.wireValue == value) {
        return code;
      }
    }
    return null;
  }
}

/// `close` の理由（設計 §2.2.1）。
enum CloseCode {
  /// サーバ側の終了。
  shutdown('SHUTDOWN'),

  /// 同じ端末が新しいセッションで接続し直した。
  sessionReplaced('SESSION_REPLACED'),

  /// アプリ側の終了。
  clientExit('CLIENT_EXIT');

  const CloseCode(this.wireValue);

  final String wireValue;

  static CloseCode? tryParse(String value) {
    for (final CloseCode code in values) {
      if (code.wireValue == value) {
        return code;
      }
    }
    return null;
  }
}

/// `error` の分類（設計 §5.1）。
enum FluseErrorCode {
  sdkNotFound('SDK_NOT_FOUND'),
  projectNotFlutter('PROJECT_NOT_FLUTTER'),
  noDevice('NO_DEVICE'),
  installSignatureConflict('INSTALL_SIGNATURE_CONFLICT'),
  protocolMismatch('PROTOCOL_MISMATCH'),
  projectMismatch('PROJECT_MISMATCH'),
  revisionMismatch('REVISION_MISMATCH'),
  appOutdated('APP_OUTDATED'),
  compileError('COMPILE_ERROR'),
  reloadRejected('RELOAD_REJECTED'),
  tunnelLost('TUNNEL_LOST'),
  authFailed('AUTH_FAILED');

  const FluseErrorCode(this.wireValue);

  final String wireValue;

  static FluseErrorCode? tryParse(String value) {
    for (final FluseErrorCode code in values) {
      if (code.wireValue == value) {
        return code;
      }
    }
    return null;
  }
}

/// `log` の深刻度（設計 §2.2.1）。
enum LogLevel {
  debug('debug'),
  info('info'),
  warn('warn'),
  error('error');

  const LogLevel(this.wireValue);

  final String wireValue;

  static LogLevel? tryParse(String value) {
    for (final LogLevel level in values) {
      if (level.wireValue == value) {
        return level;
      }
    }
    return null;
  }
}
