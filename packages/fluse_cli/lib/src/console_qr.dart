import 'package:qr/qr.dart';

/// 端末のカメラで読める QR をコンソールへ描く（設計 §2.2.4）。
///
/// **`package:qr` は行列までしか作らない。** 描画は自前で組む。
abstract final class ConsoleQr {
  /// 誤り訂正のレベル。
  ///
  /// **一番低いものにする。** 訂正を強くすると同じ内容でも版が上がり、
  /// 1マスあたりが小さくなる。コンソールに映る QR は元々粗いので、
  /// マスを大きく保つ方が読み取りやすい。汚れや欠けは画面には起きない。
  static const int errorCorrectLevel = QrErrorCorrectLevel.L;

  /// 周囲の余白（マス数）。
  ///
  /// **削ってはいけない。** QR は静穏帯が無いと読み取り位置を決められず、
  /// 端末が反応しない。仕様上の最小は4。
  static const int quietZone = 4;

  /// 上半分。
  static const String _upper = '▀';

  /// 下半分。
  static const String _lower = '▄';

  /// 両方。
  static const String _full = '█';

  /// 空。
  static const String _empty = ' ';

  /// [data] の QR を文字列にする。
  ///
  /// **2行を1行に畳む。** 1マスを1文字にすると縦長になり、普通の高さの
  /// 端末に収まらない。上下半分のブロックを使えば、縦の解像度を保ったまま
  /// 行数が半分になる。
  ///
  /// 背景を黒、マスを白として描く。**逆にしない。** 端末の背景色は
  /// 利用者ごとに違うため、明るい前景で塗った方が読み取りが安定する。
  static String render(String data) {
    final QrImage image = QrImage(
      QrCode.fromData(data: data, errorCorrectLevel: errorCorrectLevel),
    );
    final int size = image.moduleCount;
    final int total = size + quietZone * 2;

    /// (x, y) が暗いマスか。静穏帯は常に明るい。
    bool dark(int x, int y) {
      final int mx = x - quietZone;
      final int my = y - quietZone;
      if (mx < 0 || my < 0 || mx >= size || my >= size) {
        return false;
      }
      return image.isDark(my, mx);
    }

    final StringBuffer buffer = StringBuffer();
    for (int y = 0; y < total; y += 2) {
      for (int x = 0; x < total; x++) {
        // 暗いマス＝読み取り対象。ここを塗る側にする。
        final bool top = dark(x, y);
        final bool bottom = y + 1 < total && dark(x, y + 1);
        buffer.write(switch ((top, bottom)) {
          (true, true) => _full,
          (true, false) => _upper,
          (false, true) => _lower,
          (false, false) => _empty,
        });
      }
      buffer.writeln();
    }
    return buffer.toString();
  }
}
