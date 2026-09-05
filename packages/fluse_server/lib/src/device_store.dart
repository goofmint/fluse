import 'dart:convert';
import 'dart:io';

import 'session_contracts.dart';

/// `devices.json` の読み書きや解析に失敗したときに投げる。
final class DeviceStoreException implements Exception {
  const DeviceStoreException(this.message);

  final String message;

  @override
  String toString() => 'device_store: $message';
}

/// ペアリング済みの端末1台分の記録。
final class DeviceRecord {
  const DeviceRecord({
    required this.deviceId,
    required this.deviceToken,
    required this.deviceName,
    required this.issuedAt,
  });

  /// ANDROID_ID 由来のハッシュ。`hello` の `deviceId` と突き合わせる。
  final String deviceId;

  /// 再接続に使う永続トークン。
  ///
  /// **平文で保存する。** 再接続時に突合が要るためハッシュにはできない
  /// （設計 §6.1）。`.flutter_preview/` ごと `.gitignore` に入れる前提に
  /// 依存している（設計 §6.2）。
  final String deviceToken;

  /// 表示用の端末名。
  final String deviceName;

  /// 発行時刻（UTC）。
  final DateTime issuedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'deviceToken': deviceToken,
    'deviceName': deviceName,
    'issuedAt': issuedAt.toUtc().toIso8601String(),
  };

  static DeviceRecord fromJson(String deviceId, Object? json) {
    if (json is! Map<String, Object?>) {
      throw DeviceStoreException('$deviceId の記録が JSON オブジェクトではありません');
    }

    final Object? token = json['deviceToken'];
    if (token is! String || token.isEmpty) {
      throw DeviceStoreException('$deviceId の deviceToken が文字列ではありません');
    }
    final Object? name = json['deviceName'];
    if (name is! String) {
      throw DeviceStoreException('$deviceId の deviceName が文字列ではありません');
    }
    final Object? issued = json['issuedAt'];
    if (issued is! String) {
      throw DeviceStoreException('$deviceId の issuedAt が文字列ではありません');
    }
    final DateTime? parsed = DateTime.tryParse(issued);
    if (parsed == null) {
      throw DeviceStoreException('$deviceId の issuedAt を日時として読めません: $issued');
    }

    return DeviceRecord(
      deviceId: deviceId,
      deviceToken: token,
      deviceName: name,
      issuedAt: parsed,
    );
  }

  /// **トークンは含めない。** 例外文やログに混ざると漏れる。
  @override
  String toString() => 'DeviceRecord($deviceId, $deviceName)';
}

/// ペアリング済み端末の一覧を `.flutter_preview/devices.json` に持つ
/// （設計 §6.1）。
///
/// 変更は**その場でファイルへ書く**。「あとでまとめて保存」にすると、
/// 途中で落ちたときに端末側だけ新しいトークンを持ち、以後どうやっても
/// 繋がらない状態になる。
final class DeviceStore implements DeviceStoreContract {
  DeviceStore._(this._file, this._records);

  /// このファイル形式の版。
  ///
  /// 将来レコードを増やしたときに、古い `devices.json` を「読めない」と
  /// 判定できるようにするため。
  static const int currentSchemaVersion = 1;

  final File _file;
  final Map<String, DeviceRecord> _records;

  /// 保存先。
  File get file => _file;

  /// [file] から読む。**存在しなければ空として扱う。**
  ///
  /// ペアリング前は `devices.json` が無いのが正常。ここで失敗させると
  /// 初回起動が必ず落ちる。
  static DeviceStore readFrom(File file) {
    if (!file.existsSync()) {
      return DeviceStore._(file, <String, DeviceRecord>{});
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(file.readAsStringSync());
    } on FormatException catch (error) {
      throw DeviceStoreException(
        '${file.path} を JSON として読めません: ${error.message}',
      );
    }

    if (decoded is! Map<String, Object?>) {
      throw DeviceStoreException('${file.path} が JSON オブジェクトではありません');
    }

    final Object? version = decoded['schemaVersion'];
    if (version is! int) {
      throw DeviceStoreException('${file.path} の schemaVersion が整数ではありません');
    }
    if (version > currentSchemaVersion) {
      // 知らない形を推測で読むと、トークンを取りこぼして無言で再ペアリングを
      // 強いることになる。読めないことをはっきり伝える。
      throw DeviceStoreException(
        '${file.path} の schemaVersion $version は未対応です'
        '（対応は $currentSchemaVersion まで）',
      );
    }

    final Object? devices = decoded['devices'];
    if (devices is! Map<String, Object?>) {
      throw DeviceStoreException('${file.path} の devices が JSON オブジェクトではありません');
    }

    final Map<String, DeviceRecord> records = <String, DeviceRecord>{};
    for (final MapEntry<String, Object?> entry in devices.entries) {
      records[entry.key] = DeviceRecord.fromJson(entry.key, entry.value);
    }
    return DeviceStore._(file, records);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': currentSchemaVersion,
    'devices': <String, Object?>{
      for (final MapEntry<String, DeviceRecord> entry in _records.entries)
        entry.key: entry.value.toJson(),
    },
  };

  /// [file] へ書き出す。親ディレクトリが無ければ作る。
  ///
  /// **同じディレクトリの一時ファイルに書いてから差し替える。**
  /// `writeAsStringSync` は既存ファイルを切り詰めてから書くため、途中で
  /// 落ちると `devices.json` が半端な JSON のまま残る。そうなると
  /// [readFrom] が失敗し、**ペアリング済みの端末が全部繋がらなくなる**。
  /// 同一ディレクトリなら `renameSync` は差し替えとして働く。
  void writeTo(File file) {
    file.parent.createSync(recursive: true);

    final File staging = File('${file.path}.tmp');
    try {
      staging.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(toJson()),
      );
      staging.renameSync(file.path);
    } on Object {
      // 中途半端な一時ファイルを残さない。次の書き込みで邪魔になる。
      if (staging.existsSync()) {
        staging.deleteSync();
      }
      rethrow;
    }
  }

  @override
  DeviceRecord? lookup(String deviceId) => _records[deviceId];

  /// 登録済みの端末数。
  int get length => _records.length;

  /// **保存に失敗したら記憶も元に戻す。** 書けていないのに登録済みとして
  /// 振る舞うと、再起動で消えるトークンを端末に渡してしまう。
  @override
  void upsert(DeviceRecord record) {
    final DeviceRecord? previous = _records[record.deviceId];
    _records[record.deviceId] = record;
    try {
      writeTo(_file);
    } on Object {
      if (previous == null) {
        _records.remove(record.deviceId);
      } else {
        _records[record.deviceId] = previous;
      }
      rethrow;
    }
  }

  /// 消す対象が無ければ何もしない。
  ///
  /// **保存に失敗したら記憶も元に戻す。** 消えたつもりで居ると、
  /// 再起動でファイル上の登録が復活し、取り消したはずの端末が繋がる。
  @override
  void remove(String deviceId) {
    final DeviceRecord? previous = _records.remove(deviceId);
    if (previous == null) {
      return;
    }
    try {
      writeTo(_file);
    } on Object {
      _records[deviceId] = previous;
      rethrow;
    }
  }
}
