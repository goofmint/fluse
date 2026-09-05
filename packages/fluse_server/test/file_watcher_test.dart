import 'dart:async';
import 'dart:io';

import 'package:fluse_server/fluse_server.dart';
import 'package:fluse_server/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:watcher/watcher.dart' as w;

/// イベントをテストから直接流し込める [WatchTarget]。
///
/// 実イベントは順序も時刻もばらつく。監視の配線そのものは
/// `package:watcher` の責務なので、こちらは畳み込みと分類だけを見る。
final class FakeWatchTarget implements WatchTarget {
  FakeWatchTarget(this.path);

  @override
  final String path;

  final StreamController<w.WatchEvent> _controller =
      StreamController<w.WatchEvent>.broadcast();

  @override
  Stream<w.WatchEvent> get events => _controller.stream;

  @override
  Future<void> get ready => Future<void>.value();

  void emit(w.ChangeType type, String path) =>
      _controller.add(w.WatchEvent(type, path));

  void emitError(Object error) => _controller.addError(error);

  Future<void> dispose() => _controller.close();
}

void main() {
  /// テストの debounce。実時間で待つので短くする。
  const Duration debounce = Duration(milliseconds: 20);

  late Directory temp;
  late String root;
  late MemoryLogSink sink;
  late FluseLogger logger;
  final List<FakeWatchTarget> targets = <FakeWatchTarget>[];
  FileWatcher? watcher;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('fluse_watch_');
    root = temp.path;
    // 監視対象として存在させる。中身は分類に関係しない。
    Directory(p.join(root, 'lib')).createSync(recursive: true);
    Directory(
      p.join(root, 'android', 'app', 'src', 'main'),
    ).createSync(recursive: true);
    File(p.join(root, 'pubspec.yaml')).writeAsStringSync('name: sample\n');
    File(p.join(root, 'pubspec.lock')).writeAsStringSync('{}\n');

    sink = MemoryLogSink();
    logger = FluseLogger(
      sinks: <FluseLogSink>[sink],
      minimumLevel: FluseLogLevel.debug,
    );
    targets.clear();
  });

  tearDown(() async {
    await watcher?.close();
    watcher = null;
    for (final FakeWatchTarget target in targets) {
      await target.dispose();
    }
    temp.deleteSync(recursive: true);
  });

  Future<FileWatcher> start({Set<String> assets = const <String>{}}) async {
    final FileWatcher created = FileWatcher(
      projectRoot: root,
      assetPaths: assets,
      debounce: debounce,
      logger: logger,
      watcherFactory: (String path) {
        final FakeWatchTarget target = FakeWatchTarget(path);
        targets.add(target);
        return target;
      },
    );
    watcher = created;
    await created.start();
    return created;
  }

  /// 全ての監視対象へ同じイベントを流す。
  ///
  /// 実際には該当するルートの1本だけが発火するが、どのルートに割り当てる
  /// かは監視対象の決め方に依存する。テストは分類結果だけを見たい。
  void emit(w.ChangeType type, String relative) {
    final String absolute = p.join(root, relative);
    for (final FakeWatchTarget target in targets) {
      target.emit(type, absolute);
    }
  }

  /// debounce の窓が閉じるまで待つ。
  Future<void> settle() =>
      Future<void>.delayed(debounce * 3 + const Duration(milliseconds: 20));

  group('debounce', () {
    test('atomic write の連発が1イベントに畳まれる（完了条件）', () async {
      final FileWatcher w1 = await start();
      final List<ChangeSet> received = <ChangeSet>[];
      w1.changes.listen(received.add);

      // エディタの atomic write は一時ファイルへ書いて rename するため、
      // 1回の保存で create / delete / modify を連発する。
      emit(w.ChangeType.ADD, 'lib/main.dart');
      emit(w.ChangeType.REMOVE, 'lib/main.dart');
      emit(w.ChangeType.MODIFY, 'lib/main.dart');

      await settle();

      expect(received, hasLength(1));
      expect(received.single.dartSources, <String>{
        p.join(root, 'lib/main.dart'),
      });
    });

    test('複数ファイルの変更も1イベントにまとまる', () async {
      final FileWatcher w1 = await start();
      final List<ChangeSet> received = <ChangeSet>[];
      w1.changes.listen(received.add);

      emit(w.ChangeType.MODIFY, 'lib/a.dart');
      emit(w.ChangeType.MODIFY, 'lib/b.dart');

      await settle();

      expect(received, hasLength(1));
      expect(received.single.dartSources, hasLength(2));
    });

    test('窓を空けた変更は別のイベントになる', () async {
      final FileWatcher w1 = await start();
      final List<ChangeSet> received = <ChangeSet>[];
      w1.changes.listen(received.add);

      emit(w.ChangeType.MODIFY, 'lib/a.dart');
      await settle();
      emit(w.ChangeType.MODIFY, 'lib/b.dart');
      await settle();

      expect(received, hasLength(2));
    });

    test('対象外だけの変更では発火しない', () async {
      final FileWatcher w1 = await start();
      final List<ChangeSet> received = <ChangeSet>[];
      w1.changes.listen(received.add);

      emit(w.ChangeType.MODIFY, 'test/a_test.dart');
      await settle();

      expect(received, isEmpty);
    });
  });

  group('分類', () {
    test('asset の変更は asset として流れる', () async {
      final FileWatcher w1 = await start(
        assets: <String>{'assets/images/logo.png'},
      );
      final List<ChangeSet> received = <ChangeSet>[];
      w1.changes.listen(received.add);

      emit(w.ChangeType.MODIFY, 'assets/images/logo.png');
      await settle();

      expect(received.single.assets, hasLength(1));
      expect(received.single.dartSources, isEmpty);
      expect(received.single.requiresRebuild, isFalse);
    });

    test('Dart と asset が混ざっても両方に分かれる', () async {
      final FileWatcher w1 = await start(assets: <String>{'assets/'});
      final List<ChangeSet> received = <ChangeSet>[];
      w1.changes.listen(received.add);

      emit(w.ChangeType.MODIFY, 'lib/main.dart');
      emit(w.ChangeType.MODIFY, 'assets/logo.png');
      await settle();

      expect(received.single.dartSources, hasLength(1));
      expect(received.single.assets, hasLength(1));
    });
  });

  group('指紋対象', () {
    /// 指紋対象を1つ変えて、監視が止まり outdated が出ることを見る。
    Future<void> expectOutdated(String relative) async {
      final FileWatcher w1 = await start();
      final List<ChangeSet> changes = <ChangeSet>[];
      final List<ChangeSet> outdated = <ChangeSet>[];
      w1.changes.listen(changes.add);
      w1.outdated.listen(outdated.add);

      emit(w.ChangeType.MODIFY, relative);
      await settle();

      expect(outdated, hasLength(1), reason: relative);
      expect(outdated.single.fingerprintTargets, hasLength(1));
      // 増分では埋められない差分なので、通常の変更としては流さない。
      expect(changes, isEmpty, reason: relative);
      expect(w1.isWatching, isFalse, reason: relative);
    }

    test('pubspec.lock', () => expectOutdated('pubspec.lock'));

    test(
      'AndroidManifest.xml',
      () => expectOutdated('android/app/src/main/AndroidManifest.xml'),
    );

    test('gradle', () => expectOutdated('android/app/build.gradle'));

    test(
      'gradle.properties',
      () => expectOutdated('android/gradle.properties'),
    );

    test(
      'native ソース',
      () => expectOutdated('android/app/src/main/kotlin/Main.kt'),
    );

    test('停止後のイベントは処理しない', () async {
      final FileWatcher w1 = await start();
      final List<ChangeSet> changes = <ChangeSet>[];
      final List<ChangeSet> outdated = <ChangeSet>[];
      w1.changes.listen(changes.add);
      w1.outdated.listen(outdated.add);

      emit(w.ChangeType.MODIFY, 'pubspec.lock');
      await settle();
      // 作り直しが要る状態のまま増分コンパイルを走らせてはいけない。
      emit(w.ChangeType.MODIFY, 'lib/main.dart');
      await settle();

      expect(outdated, hasLength(1));
      expect(changes, isEmpty);
    });

    test('同じ回に Dart 変更が混ざっていても rebuild を優先する', () async {
      final FileWatcher w1 = await start();
      final List<ChangeSet> changes = <ChangeSet>[];
      final List<ChangeSet> outdated = <ChangeSet>[];
      w1.changes.listen(changes.add);
      w1.outdated.listen(outdated.add);

      emit(w.ChangeType.MODIFY, 'lib/main.dart');
      emit(w.ChangeType.MODIFY, 'pubspec.lock');
      await settle();

      expect(outdated, hasLength(1));
      expect(outdated.single.dartSources, hasLength(1));
      expect(changes, isEmpty);
    });
  });

  group('監視対象', () {
    test('build と .dart_tool は含めない', () async {
      // コンパイラ自身が書き込む。巻き込むと変更検出の輪ができる。
      Directory(p.join(root, 'build')).createSync();
      Directory(p.join(root, '.dart_tool')).createSync();
      final FileWatcher created = FileWatcher(
        projectRoot: root,
        debounce: debounce,
        watcherFactory: FakeWatchTarget.new,
      );

      final List<String> watched = created.watchTargets();

      expect(watched.where((String t) => t.endsWith('build')), isEmpty);
      expect(watched.where((String t) => t.endsWith('.dart_tool')), isEmpty);
      expect(watched.where((String t) => t.endsWith('lib')), hasLength(1));
    });

    test('存在しないディレクトリは飛ばす', () async {
      // android/ を持たないプロジェクトでも起動できる必要がある。
      Directory(p.join(root, 'android')).deleteSync(recursive: true);
      final FileWatcher created = FileWatcher(
        projectRoot: root,
        debounce: debounce,
        watcherFactory: FakeWatchTarget.new,
      );

      expect(
        created.watchTargets().where((String t) => t.endsWith('android')),
        isEmpty,
      );
    });

    test('プロジェクトが無ければ start で失敗する', () async {
      final FileWatcher created = FileWatcher(
        projectRoot: p.join(root, 'いない'),
        debounce: debounce,
        watcherFactory: FakeWatchTarget.new,
      );

      await expectLater(created.start(), throwsArgumentError);
    });
  });

  group('ライフサイクル', () {
    test('close は二重に呼んでも安全', () async {
      final FileWatcher w1 = await start();

      await w1.close();
      await w1.close();

      expect(w1.isWatching, isFalse);
    });

    test('close の後はイベントを処理しない', () async {
      final FileWatcher w1 = await start();
      final List<ChangeSet> received = <ChangeSet>[];
      w1.changes.listen(received.add);

      await w1.close();
      emit(w.ChangeType.MODIFY, 'lib/main.dart');
      await settle();

      expect(received, isEmpty);
    });

    test('二重 start は失敗する', () async {
      final FileWatcher w1 = await start();

      await expectLater(w1.start(), throwsStateError);
    });

    test('監視のエラーでは止まらない', () async {
      // 止めると変更が反映されなくなるのに、利用者には何も起きて
      // いないように見える。
      final FileWatcher w1 = await start();
      final List<ChangeSet> received = <ChangeSet>[];
      w1.changes.listen(received.add);

      targets.first.emitError(StateError('監視が壊れた'));
      await settle();
      emit(w.ChangeType.MODIFY, 'lib/main.dart');
      await settle();

      expect(w1.isWatching, isTrue);
      expect(received, hasLength(1));
      expect(sink.lines.where((String l) => l.contains('監視が壊れた')), isNotEmpty);
    });
  });
}
