import Foundation

/// Preview App に焼き込まれた素性（設計 §2.2.1 の `hello`）。
///
/// **端末側では決められない。** `projectId` はプロジェクトの絶対パスから、
/// `appVersion` はビルド時の指紋から作られる（設計 §4.2(a) / §2.2.2）。
/// どちらもビルドした側だけが知っている値なので、ビルド成果物に埋め込んで
/// 持ち込む。生成は Task 5.3 / 5.5 の担当。
///
/// 移植元: `packages/fluse_runtime/android/src/main/kotlin/dev/fluse/runtime/FluseAppInfo.kt`
///
/// **`load(context:)` は移植しない。** Android 版は APK の assets から
/// 読むが、iOS 側では `Bundle` からの読み込みに置き換わり、実行環境
/// （Flutter エンジン込みのアプリ本体）が無いと確かめられない。ここでは
/// Android のランタイムに触らない `parse(text:)` だけを対象にする
/// （Task 9.2 の範囲外。iOS 側の読み込みは別チケットで扱う）。
public struct FluseAppInfo: Equatable {
    public let projectId: String
    public let flutterRevision: String
    public let dartVersion: String
    public let appVersion: String

    public init(
        projectId: String,
        flutterRevision: String,
        dartVersion: String,
        appVersion: String
    ) {
        self.projectId = projectId
        self.flutterRevision = flutterRevision
        self.dartVersion = dartVersion
        self.appVersion = appVersion
    }

    /// ビルド時に書き込まれる場所。生成側と揃えること。
    ///
    /// エラー文言の中でしか使わないが、Android 版の `ASSET_PATH` と同じ
    /// 役割で残しておく（どのファイルの話かがログから追えるように）。
    public static let assetPath = "fluse/app_info.json"

    /// JSON から組み立てる。ランタイムに触らないので単体で確かめられる。
    ///
    /// **無ければ落とす。** 既定値で埋めると、別プロジェクトのサーバに
    /// 繋がったり、古いビルドが新しいサーバに受理されたりする。どちらも
    /// 「なぜか動かない」形で表面化して切り分けが難しい。
    public static func parse(text: String) throws -> FluseAppInfo {
        guard let data = text.data(using: .utf8) else {
            throw FluseProtocolException("\(assetPath) を UTF-8 として読めません")
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let json = object as? [String: Any]
        else {
            throw FluseProtocolException("\(assetPath) が JSON オブジェクトではありません")
        }
        let reader = JsonReader(json)
        return FluseAppInfo(
            projectId: try requireNonEmpty(reader, "projectId"),
            flutterRevision: try requireNonEmpty(reader, "flutterRevision"),
            dartVersion: try requireNonEmpty(reader, "dartVersion"),
            appVersion: try requireNonEmpty(reader, "appVersion")
        )
    }

    /// Kotlin の `require()`（`json.optString(key)` が空文字なら例外）に相当。
    ///
    /// `JsonReader.requireString` は「キーが無い」「型が違う」までしか
    /// 見ないため、Kotlin と同じく空文字も明示的に弾く。
    private static func requireNonEmpty(_ reader: JsonReader, _ key: String) throws -> String {
        let value = try reader.requireString(assetPath, key)
        guard !value.isEmpty else {
            throw FluseProtocolException("\(assetPath) に \(key) がありません")
        }
        return value
    }
}
