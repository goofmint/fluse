/// `adb devices -l` が返す端末1台（設計 §2.2.2）。
final class AndroidDevice {
  const AndroidDevice({
    required this.serial,
    required this.model,
    this.product,
    this.transportId,
  });

  /// `adb -s` に渡す識別子。
  final String serial;

  /// 利用者が自分の端末を見分けるための名前。
  ///
  /// `adb` が返さない場合は [serial] を入れる。**空にしない。**
  /// 選ぶ画面に何も出ないと、どれを選べばよいか分からなくなる。
  final String model;

  /// 端末の製品名。無ければ null。
  final String? product;

  /// 同じ serial が複数ある時の区別（USB と TCP/IP の同居など）。
  final String? transportId;

  /// 一覧に出す表示。
  String get label => model == serial ? serial : '$model ($serial)';

  @override
  String toString() => 'AndroidDevice($label)';
}
