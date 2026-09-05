import 'package:yaml/yaml.dart';

/// `pubspec.yaml` の asset 宣言を読めなかったときに投げる。
final class AssetManifestException implements Exception {
  const AssetManifestException(this.message);

  final String message;

  @override
  String toString() => 'asset: $message';
}

/// `fonts:` の1書体。
final class FontAsset {
  const FontAsset({required this.asset, this.weight, this.style});

  /// プロジェクトルートからの相対パス。
  final String asset;

  /// 宣言された太さ。**ファイル名からは推測しない。**
  ///
  /// `Inconsolata-Bold.ttf` を 700 と決めつけると、宣言と食い違ったときに
  /// 端末側の描画だけが静かにずれる。宣言が唯一の情報源。
  final int? weight;

  /// 宣言されたスタイル（`normal` / `italic`）。
  final String? style;

  Map<String, Object?> toJson() => <String, Object?>{
    'asset': asset,
    if (weight != null) 'weight': weight,
    if (style != null) 'style': style,
  };

  @override
  String toString() => 'FontAsset($asset)';
}

/// `fonts:` の1ファミリ。
final class FontFamily {
  const FontFamily({required this.family, required this.fonts});

  final String family;
  final List<FontAsset> fonts;

  Map<String, Object?> toJson() => <String, Object?>{
    'family': family,
    'fonts': <Object?>[for (final FontAsset font in fonts) font.toJson()],
  };

  @override
  String toString() => 'FontFamily($family, ${fonts.length} fonts)';
}

/// `pubspec.yaml` の `flutter:` セクションから読み取った宣言。
final class AssetDeclarations {
  const AssetDeclarations({required this.assets, required this.fonts});

  /// 空の宣言。`flutter:` が無いプロジェクトを表す。
  static const AssetDeclarations empty = AssetDeclarations(
    assets: <String>[],
    fonts: <FontFamily>[],
  );

  /// `assets:` に並んだ値。末尾が `/` ならディレクトリ宣言。
  final List<String> assets;

  final List<FontFamily> fonts;

  bool get isEmpty => assets.isEmpty && fonts.isEmpty;

  @override
  String toString() =>
      'AssetDeclarations(${assets.length} assets, ${fonts.length} families)';
}

/// `pubspec.yaml` から asset / font の宣言を取り出す（設計 §2.2.3(b)）。
///
/// **宣言の解釈だけを行い、ファイルは触らない。** 実ファイルへの展開は
/// `AssetBundleService` の責務。ここを純粋に保つと、pubspec の書き方の
/// 網羅テストがファイルシステム無しで書ける。
abstract final class AssetManifestParser {
  /// [pubspecYaml] を解析する。
  ///
  /// `flutter:` や `assets:` / `fonts:` が無ければ空の結果を返す。
  /// 型が食い違う場合は [AssetManifestException] を投げる。**黙って
  /// 飛ばすと、宣言したはずの asset が届かない理由が分からなくなる。**
  static AssetDeclarations parse(String pubspecYaml) {
    final Object? document;
    try {
      document = loadYaml(pubspecYaml);
    } on YamlException catch (error) {
      throw AssetManifestException(
        'pubspec.yaml を YAML として読めません: ${error.message}',
      );
    }

    if (document == null) {
      return AssetDeclarations.empty;
    }
    if (document is! Map) {
      throw const AssetManifestException('pubspec.yaml が YAML のマップではありません');
    }

    final Object? flutter = document['flutter'];
    if (flutter == null) {
      // Flutter プロジェクトでなければ asset もフォントも無い。
      return AssetDeclarations.empty;
    }
    if (flutter is! Map) {
      throw const AssetManifestException('pubspec.yaml の flutter: がマップではありません');
    }

    return AssetDeclarations(
      assets: _parseAssets(flutter['assets']),
      fonts: _parseFonts(flutter['fonts']),
    );
  }

  static List<String> _parseAssets(Object? node) {
    if (node == null) {
      return const <String>[];
    }
    if (node is! List) {
      throw const AssetManifestException('flutter: の assets: がリストではありません');
    }

    final List<String> assets = <String>[];
    for (final Object? entry in node) {
      if (entry is! String) {
        throw AssetManifestException('assets: の要素が文字列ではありません: $entry');
      }
      if (entry.isEmpty) {
        throw const AssetManifestException('assets: に空の要素があります');
      }
      assets.add(entry);
    }
    return assets;
  }

  static List<FontFamily> _parseFonts(Object? node) {
    if (node == null) {
      return const <FontFamily>[];
    }
    if (node is! List) {
      throw const AssetManifestException('flutter: の fonts: がリストではありません');
    }

    final List<FontFamily> families = <FontFamily>[];
    for (final Object? entry in node) {
      if (entry is! Map) {
        throw AssetManifestException('fonts: の要素がマップではありません: $entry');
      }

      final Object? family = entry['family'];
      if (family is! String || family.isEmpty) {
        throw AssetManifestException('fonts: の family が文字列ではありません: $family');
      }

      final Object? fontNodes = entry['fonts'];
      if (fontNodes == null) {
        // family だけの宣言は書体が1つも無い。届けるものが無いので弾く。
        throw AssetManifestException('fonts: の $family に fonts: がありません');
      }
      if (fontNodes is! List) {
        throw AssetManifestException('fonts: の $family の fonts: がリストではありません');
      }

      final List<FontAsset> fonts = <FontAsset>[];
      for (final Object? fontNode in fontNodes) {
        if (fontNode is! Map) {
          throw AssetManifestException('$family の fonts: の要素がマップではありません');
        }
        final Object? asset = fontNode['asset'];
        if (asset is! String || asset.isEmpty) {
          throw AssetManifestException('$family の font に asset がありません');
        }

        final Object? weight = fontNode['weight'];
        if (weight != null && weight is! int) {
          throw AssetManifestException('$family の font の weight が整数ではありません');
        }
        final Object? style = fontNode['style'];
        if (style != null && style is! String) {
          throw AssetManifestException('$family の font の style が文字列ではありません');
        }

        fonts.add(
          FontAsset(
            asset: asset,
            weight: weight as int?,
            style: style as String?,
          ),
        );
      }

      families.add(FontFamily(family: family, fonts: fonts));
    }
    return families;
  }
}
