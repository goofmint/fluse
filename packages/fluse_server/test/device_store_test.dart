import 'dart:convert';
import 'dart:io';

import 'package:fluse_server/fluse_server.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late File file;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('fluse_device_store_');
    file = File(p.join(temp.path, '.flutter_preview', 'devices.json'));
  });

  tearDown(() => temp.deleteSync(recursive: true));

  DeviceRecord record(String deviceId, String token) => DeviceRecord(
    deviceId: deviceId,
    deviceToken: token,
    deviceName: 'Pixel 8',
    issuedAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
  );

  test('ファイルが無ければ空として開ける', () {
    // ペアリング前は devices.json が無いのが正常。落としてはいけない。
    final DeviceStore store = DeviceStore.readFrom(file);

    expect(store.length, 0);
    expect(store.lookup('device-1'), isNull);
  });

  test('upsert すると親ディレクトリごと作って保存する', () {
    final DeviceStore store = DeviceStore.readFrom(file);
    store.upsert(record('device-1', 'token-1'));

    expect(file.existsSync(), isTrue);
    final DeviceStore reopened = DeviceStore.readFrom(file);
    expect(reopened.lookup('device-1')?.deviceToken, 'token-1');
    expect(reopened.lookup('device-1')?.deviceName, 'Pixel 8');
  });

  test('同じ deviceId の upsert は上書きになる', () {
    final DeviceStore store = DeviceStore.readFrom(file);
    store.upsert(record('device-1', 'token-1'));
    store.upsert(record('device-1', 'token-2'));

    expect(store.length, 1);
    expect(
      DeviceStore.readFrom(file).lookup('device-1')?.deviceToken,
      'token-2',
    );
  });

  test('records は発行順に並べて返す', () {
    final DeviceStore store = DeviceStore.readFrom(file);
    store.upsert(
      DeviceRecord(
        deviceId: 'device-2',
        deviceToken: 'token-2',
        deviceName: 'あと',
        issuedAt: DateTime.utc(2026, 2, 1),
      ),
    );
    store.upsert(
      DeviceRecord(
        deviceId: 'device-1',
        deviceToken: 'token-1',
        deviceName: 'さき',
        issuedAt: DateTime.utc(2026, 1, 1),
      ),
    );

    expect(
      store.records.map((DeviceRecord r) => r.deviceName).toList(),
      <String>['さき', 'あと'],
    );
    // 触っても記憶は動かない。
    expect(() => store.records.clear(), throwsUnsupportedError);
  });

  test('remove すると保存内容からも消える', () {
    final DeviceStore store = DeviceStore.readFrom(file);
    store.upsert(record('device-1', 'token-1'));
    store.upsert(record('device-2', 'token-2'));

    store.remove('device-1');

    final DeviceStore reopened = DeviceStore.readFrom(file);
    expect(reopened.lookup('device-1'), isNull);
    expect(reopened.lookup('device-2')?.deviceToken, 'token-2');
  });

  test('存在しない deviceId の remove は何もしない', () {
    final DeviceStore store = DeviceStore.readFrom(file);
    store.upsert(record('device-1', 'token-1'));

    store.remove('device-x');

    expect(store.length, 1);
  });

  group('保存に失敗したとき', () {
    /// 書き込み先をディレクトリで塞ぐ。
    ///
    /// `writeTo` は同じディレクトリの `<path>.tmp` に書いてから rename する。
    /// rename 先が既存ディレクトリだと FileSystemException になる。
    void blockDestination() {
      Directory(file.path).createSync(recursive: true);
    }

    test('upsert が失敗したら登録も元に戻る', () {
      final DeviceStore store = DeviceStore.readFrom(file);
      blockDestination();

      expect(
        () => store.upsert(record('device-1', 'token-1')),
        throwsA(isA<FileSystemException>()),
      );
      // 書けていないのに登録済みとして振る舞うと、再起動で消える
      // トークンを端末に渡してしまう。
      expect(store.lookup('device-1'), isNull);
    });

    test('upsert の上書きが失敗したら前の値に戻る', () {
      final DeviceStore store = DeviceStore.readFrom(file);
      store.upsert(record('device-1', 'token-1'));
      file.deleteSync();
      blockDestination();

      expect(
        () => store.upsert(record('device-1', 'token-2')),
        throwsA(isA<FileSystemException>()),
      );
      expect(store.lookup('device-1')?.deviceToken, 'token-1');
    });

    test('remove が失敗したら登録が残る', () {
      final DeviceStore store = DeviceStore.readFrom(file);
      store.upsert(record('device-1', 'token-1'));
      file.deleteSync();
      blockDestination();

      expect(
        () => store.remove('device-1'),
        throwsA(isA<FileSystemException>()),
      );
      // 消えたつもりで居ると、再起動で登録が復活して取り消しが効かない。
      expect(store.lookup('device-1')?.deviceToken, 'token-1');
    });

    test('一時ファイルを残さない', () {
      final DeviceStore store = DeviceStore.readFrom(file);
      blockDestination();

      expect(
        () => store.upsert(record('device-1', 'token-1')),
        throwsA(isA<FileSystemException>()),
      );
      expect(File('${file.path}.tmp').existsSync(), isFalse);
    });
  });

  test('toString にトークンを含めない', () {
    expect(
      record('device-1', 'token-1').toString(),
      isNot(contains('token-1')),
    );
  });

  group('壊れた devices.json', () {
    void write(Object? content) {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(content is String ? content : jsonEncode(content));
    }

    test('JSON として読めなければ失敗する', () {
      write('{ぐちゃぐちゃ');

      expect(
        () => DeviceStore.readFrom(file),
        throwsA(isA<DeviceStoreException>()),
      );
    });

    test('JSON オブジェクトでなければ失敗する', () {
      write(<Object?>[]);

      expect(
        () => DeviceStore.readFrom(file),
        throwsA(isA<DeviceStoreException>()),
      );
    });

    test('schemaVersion が無ければ失敗する', () {
      write(<String, Object?>{'devices': <String, Object?>{}});

      expect(
        () => DeviceStore.readFrom(file),
        throwsA(isA<DeviceStoreException>()),
      );
    });

    test('未対応の新しい schemaVersion は拒否する', () {
      // 推測で読むとトークンを取りこぼし、無言で再ペアリングを強いる。
      write(<String, Object?>{
        'schemaVersion': DeviceStore.currentSchemaVersion + 1,
        'devices': <String, Object?>{},
      });

      expect(
        () => DeviceStore.readFrom(file),
        throwsA(
          isA<DeviceStoreException>().having(
            (DeviceStoreException e) => e.message,
            'message',
            contains('未対応'),
          ),
        ),
      );
    });

    test('deviceToken が欠けていれば失敗する', () {
      write(<String, Object?>{
        'schemaVersion': DeviceStore.currentSchemaVersion,
        'devices': <String, Object?>{
          'device-1': <String, Object?>{
            'deviceName': 'Pixel 8',
            'issuedAt': '2026-01-02T03:04:05Z',
          },
        },
      });

      expect(
        () => DeviceStore.readFrom(file),
        throwsA(isA<DeviceStoreException>()),
      );
    });

    test('issuedAt が日時として読めなければ失敗する', () {
      write(<String, Object?>{
        'schemaVersion': DeviceStore.currentSchemaVersion,
        'devices': <String, Object?>{
          'device-1': <String, Object?>{
            'deviceToken': 'token-1',
            'deviceName': 'Pixel 8',
            'issuedAt': 'きのう',
          },
        },
      });

      expect(
        () => DeviceStore.readFrom(file),
        throwsA(isA<DeviceStoreException>()),
      );
    });
  });
}
