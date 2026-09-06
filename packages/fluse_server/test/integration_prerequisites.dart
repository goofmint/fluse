/// 統合テスト（L1 / L2 / L3）の前提の扱いを1箇所にまとめる。**テスト専用**。
library;

import 'dart:io';

import 'package:test/test.dart';

/// 前提が揃っていない時に、飛ばすか落とすかを決める。
///
/// **CI では飛ばさない。** 前提を整えたはずのジョブでテストが自分から
/// スキップすると、何も検証していないのに緑になる。それでは「PR で全
/// チェックが自動実行される」を満たしたことにならない。
///
/// 手元では飛ばす。Android SDK も JDK も無い環境で `dart test` を流した
/// だけで落ちるのでは、他のテストの結果が読めない。
///
/// [reason] が null なら前提は揃っている。[requireEnv] に指定した環境変数が
/// `1` の時だけ、揃っていないことを失敗として扱う。
bool ensurePrerequisiteReason(String? reason, {required String requireEnv}) {
  if (reason == null) {
    return true;
  }
  if (Platform.environment[requireEnv] == '1') {
    fail('$requireEnv=1 だが前提が揃っていない: $reason');
  }
  markTestSkipped(reason);
  return false;
}
