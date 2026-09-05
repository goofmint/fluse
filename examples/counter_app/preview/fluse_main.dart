/// Task 4.1 の動作確認用エントリポイント。
///
/// **本番ではこのファイルは要らない。** `fluse init` が
/// `.flutter_preview/fluse_main.dart` を生成する（設計 §2.2.2 /
/// Task 5.3 の `EntrypointGenerator`）。生成されるものと同じ形をここに
/// 置いておくのは、ジェネレータができるまでの間、手で
/// `flutter run -t preview/fluse_main.dart` を叩いて
/// VM Service の URI が Native に届くか（logcat）を確かめるため。
///
/// `lib/` の外に置くのは、生成物の位置（`.flutter_preview/`）に合わせる
/// ためと、dev_dependency を `lib/` から参照しないため。
library;

import 'package:counter_app/main.dart' as app;
import 'package:fluse_runtime/fluse_runtime.dart';

Future<void> main() => flusePreviewMain(app.main);
