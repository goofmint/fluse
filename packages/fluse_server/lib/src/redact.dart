/// ログに出す前に秘密情報をマスクするためのユーティリティ。
///
/// 設計 §6.1 の「トークンは常にマスク（先頭4文字 + `***`）」を実装する。
/// マスクは**出力の直前**ではなく**ログイベントを組み立てる時点**で適用する。
/// 「この経路だけマスクを忘れた」を作らないため、[FluseLogger] は全ての
/// 出力経路でこれを通す。
library;

/// 値をマスクすべきと判断するキー名。
///
/// 比較は小文字化した上での部分一致で行う。`deviceToken` / `device_token` /
/// `issuedDeviceToken` のような表記ゆれを個別に列挙せずに済ませるため。
const Set<String> _secretKeyFragments = {
  'token',
  'secret',
  'password',
  'passwd',
  'authcode',
  'credential',
};

/// マスク後に付ける記号。
const String _mask = '***';

/// トークン1個をマスクする。
///
/// 先頭4文字を残して残りを [_mask] に置き換える。ただし**5文字未満の値は
/// 全体をマスクする**。4文字しかない値の先頭4文字を残すと元の値がそのまま
/// 残ってしまい、マスクの意味が無くなるため。
String maskToken(String value) {
  if (value.length < 5) {
    return _mask;
  }
  return '${value.substring(0, 4)}$_mask';
}

/// 構造化データを再帰的に走査し、秘密情報を含むキーの値をマスクした
/// 新しいデータを返す。引数は変更しない。
///
/// - [Map] のキーが [_secretKeyFragments] のいずれかを含めば、その値をマスクする
/// - [Map] / [Iterable] は中身を再帰的に処理する
/// - 文字列は [redactVmServiceUri] と [redactSecrets] を通す
///
/// [secrets] には既知のトークン値そのものを渡す。キー名に現れない場所
/// （例外メッセージ、外部プロセスの stderr など）に混ざったトークンを
/// 消すため。
Object? redact(Object? value, {Iterable<String> secrets = const <String>[]}) {
  if (value is Map) {
    return <String, Object?>{
      for (final MapEntry<Object?, Object?> entry in value.entries)
        '${entry.key}': _isSecretKey('${entry.key}')
            ? _maskAny(entry.value)
            : redact(entry.value, secrets: secrets),
    };
  }
  return _redactNonMap(value, secrets);
}

/// [Map] 専用の入口。
///
/// [redact] の戻り値は [Object?] なので、Map と分かっている経路で使うと
/// 呼び出し側に強制キャストが必要になる。それを避けるためのもの。
Map<String, Object?> redactMap(
  Map<String, Object?> value, {
  Iterable<String> secrets = const <String>[],
}) {
  return <String, Object?>{
    for (final MapEntry<String, Object?> entry in value.entries)
      entry.key: _isSecretKey(entry.key)
          ? _maskAny(entry.value)
          : redact(entry.value, secrets: secrets),
  };
}

Object? _redactNonMap(Object? value, Iterable<String> secrets) {
  if (value is Iterable) {
    return value.map((Object? e) => redact(e, secrets: secrets)).toList();
  }
  if (value is String) {
    return redactSecrets(redactVmServiceUri(value), secrets);
  }
  return value;
}

/// 文中に現れる URI を探し、[_maskUriAuthCode] を通した文字列を返す。
///
/// ログの `message` は「vm service at http://... 」のように地の文へ URI が
/// 埋まる形が多いため、文字列全体を URI とみなす実装では取りこぼす。
String redactVmServiceUri(String text) {
  if (!text.contains('://')) {
    return text;
  }
  return text.replaceAllMapped(
    _uriPattern,
    (Match m) => _maskUriAuthCode(m[0]!),
  );
}

/// http / https / ws / wss の URI。空白と引用符で終端する。
final RegExp _uriPattern = RegExp(r'''(?:https?|wss?)://[^\s"'<>]+''');

/// VM Service の URI に含まれる認証コードをマスクする。
///
/// VM Service は `http://127.0.0.1:<port>/<authCode>/` という形式で、
/// **パスセグメントそのものが認証情報**になっている。これを掴んだ相手は
/// DevFS への書き込みも `reloadSources` の実行もできるため、トークンと
/// 同格に扱う必要がある。
///
/// URI として解釈できない文字列や、認証コードを持たない URI はそのまま返す。
String _maskUriAuthCode(String raw) {
  final Uri? uri = Uri.tryParse(raw);
  if (uri == null || !uri.hasAuthority) {
    return raw;
  }

  Uri masked = uri;
  bool changed = false;

  // (1) パスセグメントの認証コード。
  // 末尾の空セグメント（`.../` の表現）は残す。落とすと URI の形が変わる。
  final List<String> segments = List<String>.of(uri.pathSegments);
  final int index = segments.indexWhere((String s) => s.isNotEmpty);
  // VM Service の認証コードは base64url 風の十分に長い1セグメント。
  // `/health` のような通常のパスを巻き込まないよう長さで足切りする。
  if (index >= 0 && segments[index].length >= 8) {
    segments[index] = maskToken(segments[index]);
    masked = masked.replace(pathSegments: segments);
    changed = true;
  }

  // (2) クエリの秘密パラメータ。`/apk?t=<pairingToken>`（設計 §4.2(b)）など。
  //
  // Uri.replace(queryParameters:) は値をパーセントエンコードするため、
  // マスク記号が `%2A%2A%2A` になってログが読めなくなる。クエリ文字列を
  // 自前で組み立て、マスク済みの値だけエンコードせずに置く。
  if (uri.hasQuery && uri.queryParameters.isNotEmpty) {
    final List<String> parts = <String>[];
    bool queryChanged = false;
    for (final MapEntry<String, String> e in uri.queryParameters.entries) {
      final String key = Uri.encodeQueryComponent(e.key);
      if (_isSecretKey(e.key) || _isShortSecretQueryKey(e.key)) {
        parts.add('$key=${maskToken(e.value)}');
        queryChanged = true;
      } else {
        parts.add('$key=${Uri.encodeQueryComponent(e.value)}');
      }
    }
    if (queryChanged) {
      masked = masked.replace(query: parts.join('&'));
      changed = true;
    }
  }

  // (3) userInfo は `user:password` 形式で必ず資格情報。無条件に潰す。
  if (uri.userInfo.isNotEmpty) {
    masked = masked.replace(userInfo: _mask);
    changed = true;
  }

  return changed ? masked.toString() : raw;
}

/// クエリでよく使われる短い秘密キー。
///
/// `_isSecretKey` は部分一致なので `t` のような1文字キーは拾えない。
/// クエリに限っては完全一致で補う。
bool _isShortSecretQueryKey(String key) =>
    const <String>{'t', 'k', 'pw', 'auth'}.contains(key.toLowerCase());

/// 既知の秘密値そのものを本文から消す。
///
/// キー名に現れない場所（例外メッセージ、外部プロセスの stderr など）に
/// トークンが混ざる経路があるため、値そのものでも置換できるようにする。
/// [secrets] は空文字と5文字未満の値を無視する（誤爆を避けるため）。
String redactSecrets(String text, Iterable<String> secrets) {
  String result = text;
  for (final String secret in secrets) {
    if (secret.length < 5) {
      continue;
    }
    result = result.replaceAll(secret, maskToken(secret));
  }
  return result;
}

bool _isSecretKey(String key) {
  final String lower = key.toLowerCase();
  return _secretKeyFragments.any(lower.contains);
}

/// 秘密キーに紐づく値をマスクする。文字列以外も握りつぶさず、
/// 構造ごとマスクして「そこに何かがあった」ことは残す。
Object? _maskAny(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is String) {
    return maskToken(value);
  }
  if (value is Map || value is Iterable) {
    return _mask;
  }
  return _mask;
}
