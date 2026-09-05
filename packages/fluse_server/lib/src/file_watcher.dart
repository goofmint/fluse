import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:watcher/watcher.dart' as w;

import 'change_classifier.dart';
import 'fluse_logger.dart';

/// [FileWatcher] が使う監視の面。
///
/// 実装はプラットフォーム依存（inotify / FSEvents）で、テストから
/// 実イベントを狙って起こすのは現実的でない。必要な形だけを契約に切り出す。
abstract interface class WatchTarget {
  /// 監視対象のパス。
  String get path;

  /// 変更イベント。
  Stream<w.WatchEvent> get events;

  /// 監視が始まったら完了する。
  Future<void> get ready;
}

/// `package:watcher` をそのまま使う既定実装。
///
/// ディレクトリとファイルで別のクラスが要る。指紋対象には
/// `pubspec.lock` のような単体のファイルが含まれる。
final class SystemWatchTarget implements WatchTarget {
  SystemWatchTarget(this.path)
    : _delegate = FileSystemEntity.isDirectorySync(path)
          ? w.DirectoryWatcher(path)
          : w.FileWatcher(path);

  @override
  final String path;

  final w.Watcher _delegate;

  @override
  Stream<w.WatchEvent> get events => _delegate.events;

  @override
  Future<void> get ready => _delegate.ready;
}

/// 監視対象1つ分の [WatchTarget] を作る。
typedef WatchTargetFactory = WatchTarget Function(String path);

/// ソース変更を見張る（設計 §2.2.3 / §3.2）。
///
/// **保存1回が複数のイベントになる。** エディタの atomic write は
/// 一時ファイルへ書いて rename するため、create / delete / modify を
/// 連発する。そのまま流すと1回の保存で何度もコンパイルが走る。
/// [debounce] で畳んで1回にする（設計 §8.2-3）。
///
/// 指紋対象（設計 §2.2.2）が変わったら**監視を止める**。増分コンパイルでは
/// 埋められない差分なので、走り続けると「リロードしても直らない」状態に
/// なる。`fluse rebuild` に誘導するのは呼び出し側（Task 3.5）の仕事。
final class FileWatcher {
  FileWatcher({
    required String projectRoot,
    Set<String> assetPaths = const <String>{},
    this.debounce = defaultDebounce,
    FluseLogger? logger,
    WatchTargetFactory? watcherFactory,
  }) : projectRoot = p.normalize(p.absolute(projectRoot)),
       _assetPaths = Set<String>.unmodifiable(assetPaths),
       _classifier = ChangeClassifier(
         projectRoot: projectRoot,
         assetPaths: assetPaths,
       ),
       _logger = logger,
       _watcherFactory = watcherFactory ?? SystemWatchTarget.new;

  /// 保存1回分を畳む幅（設計 §8.2-3）。
  static const Duration defaultDebounce = Duration(milliseconds: 50);

  /// プロジェクトの絶対パス。
  final String projectRoot;

  /// 変更を畳む幅。
  final Duration debounce;

  final Set<String> _assetPaths;
  final ChangeClassifier _classifier;
  final FluseLogger? _logger;
  final WatchTargetFactory _watcherFactory;

  final List<StreamSubscription<w.WatchEvent>> _subscriptions =
      <StreamSubscription<w.WatchEvent>>[];

  final StreamController<ChangeSet> _changes =
      StreamController<ChangeSet>.broadcast();
  final StreamController<ChangeSet> _outdated =
      StreamController<ChangeSet>.broadcast();

  /// debounce の窓に溜めているパス。
  final Set<String> _pending = <String>{};
  Timer? _timer;

  bool _started = false;
  bool _closed = false;

  /// 反映すべき変更。指紋対象を含む回はここには流れない。
  Stream<ChangeSet> get changes => _changes.stream;

  /// 指紋対象が変わったこと（`APP_OUTDATED`）。
  ///
  /// **この後 [isWatching] は false になる。** 呼び出し側は利用者へ
  /// `fluse rebuild` を案内すること。
  Stream<ChangeSet> get outdated => _outdated.stream;

  /// 監視中か。
  bool get isWatching => _started && !_closed;

  /// 監視を始める。
  ///
  /// `lib/`・宣言された asset・指紋対象のルートを見る。存在しない
  /// ディレクトリは黙って飛ばす。`android/` を持たないプロジェクトでも
  /// 起動できるようにするため。
  Future<void> start() async {
    if (_started) {
      throw StateError('すでに start 済みです');
    }
    if (_closed) {
      throw StateError('すでに close 済みです');
    }
    _started = true;

    for (final String target in watchTargets()) {
      final WatchTarget watcher = _watcherFactory(target);
      _subscriptions.add(watcher.events.listen(_onEvent, onError: _onError));
      await watcher.ready;
    }

    _logger?.debug(
      'ファイル監視を開始しました',
      fields: <String, Object?>{
        'root': projectRoot,
        'debounceMs': debounce.inMilliseconds,
      },
    );
  }

  /// 監視を止める。二重に呼んでも安全。
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;

    _timer?.cancel();
    _timer = null;
    _pending.clear();

    try {
      // 1本の失敗で残りを止めない。閉じ損ねた購読が生き残る方が困る。
      for (final StreamSubscription<w.WatchEvent> subscription
          in _subscriptions) {
        try {
          await subscription.cancel();
        } on Object catch (error) {
          _logger?.warn('監視の解除に失敗しました: $error');
        }
      }
    } finally {
      _subscriptions.clear();
      await _changes.close();
      await _outdated.close();
    }
  }

  /// 実際に監視するパス。存在しないものは含めない。
  ///
  /// **プロジェクト直下を丸ごとは見ない。** `build/` と `.dart_tool/` には
  /// コンパイラ自身が書き込む。巻き込むと、コンパイル → 変更検出 →
  /// コンパイルの輪ができて止まらなくなる。
  List<String> watchTargets() {
    if (!Directory(projectRoot).existsSync()) {
      throw ArgumentError.value(projectRoot, 'projectRoot', 'ディレクトリがありません');
    }

    final Set<String> targets = <String>{};
    void add(String relative) {
      final String absolute = p.normalize(p.join(projectRoot, relative));
      if (FileSystemEntity.typeSync(absolute) ==
          FileSystemEntityType.notFound) {
        // android/ を持たないプロジェクトでも起動できるようにする。
        return;
      }
      targets.add(absolute);
    }

    add('lib');
    // 指紋対象のうち android/ 配下は全てここに入る。
    add('android');
    for (final String file in ChangeClassifier.fingerprintFiles) {
      add(file);
    }
    for (final String asset in _assetPaths) {
      // ディレクトリ宣言（末尾 /）はそのディレクトリごと見る。
      add(asset.endsWith('/') ? asset : p.dirname(asset));
    }
    return targets.toList()..sort();
  }

  void _onError(Object error) {
    // 監視が壊れても止めない。記録だけして続ける。止めると変更が
    // 反映されなくなるのに、利用者には何も起きていないように見える。
    _logger?.warn('ファイル監視でエラーが発生しました: $error');
  }

  void _onEvent(w.WatchEvent event) {
    if (!isWatching) {
      return;
    }
    _pending.add(event.path);

    // **窓を延長する。** 保存中の連発を1回に畳むのが目的なので、
    // 最後のイベントから debounce だけ待つ。
    _timer?.cancel();
    _timer = Timer(debounce, _flush);
  }

  void _flush() {
    _timer = null;
    if (!isWatching) {
      return;
    }

    final Set<String> paths = _pending.toSet();
    _pending.clear();

    final Set<String> dartSources = <String>{};
    final Set<String> assets = <String>{};
    final Set<String> fingerprints = <String>{};
    for (final String path in paths) {
      switch (_classifier.classify(path)) {
        case ChangeKind.dartSource:
          dartSources.add(path);
        case ChangeKind.asset:
          assets.add(path);
        case ChangeKind.fingerprintTarget:
          fingerprints.add(path);
        case ChangeKind.ignored:
          break;
      }
    }

    final ChangeSet changeSet = ChangeSet(
      dartSources: dartSources,
      assets: assets,
      fingerprintTargets: fingerprints,
    );
    if (changeSet.isEmpty) {
      return;
    }

    if (changeSet.requiresRebuild) {
      // **止めてから通知する。** 通知の処理中に次のイベントが来ると、
      // 作り直しが要る状態のまま増分コンパイルが走る。
      _logger?.warn(
        '指紋対象が変更されました。監視を停止します',
        fields: <String, Object?>{
          'files': fingerprints.map(_relative).toList(),
        },
      );
      _started = false;
      _outdated.add(changeSet);
      return;
    }

    _logger?.debug(
      'ファイルの変更を検出しました',
      fields: <String, Object?>{
        'dart': dartSources.map(_relative).toList(),
        'assets': assets.map(_relative).toList(),
      },
    );
    _changes.add(changeSet);
  }

  String _relative(String path) => p.relative(path, from: projectRoot);
}
