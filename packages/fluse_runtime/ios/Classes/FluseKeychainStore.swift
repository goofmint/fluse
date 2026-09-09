import Foundation
import Security
import os.log

/**
 * 値の置き場（設計 §2.2.5 / §6.1）。
 *
 * 移植元: `packages/fluse_runtime/android/src/main/kotlin/dev/fluse/runtime/FluseStore.kt`
 * （`FluseBacking` / `PreferencesBacking` / `MemoryBacking` / `FluseStore` 全体）。
 *
 * Keychain が使える環境とそうでない環境で実体を差し替えるために挟む。
 * Kotlin 版の `internal interface FluseBacking` と同じ役割で、
 * アクセスレベルも同じく internal にしてある（この PR の外からは
 * `FluseKeychainStore` 経由でしか触れない）。
 */
protocol FluseBacking: AnyObject {
    func getString(_ key: String) -> String?
    func putString(_ key: String, _ value: String?)
    func getInt(_ key: String, fallback: Int) -> Int
    func putInt(_ key: String, _ value: Int)
    func clear()

    /// ディスクに残るか。残らないなら再起動で消える。
    var isPersistent: Bool { get }
}

/**
 * メモリにだけ置く。**プロセスが終われば消える。**
 *
 * Keychain が使えない環境（Issue #95 の完了条件にある「Keychain が使えない
 * 環境でもセッション中は動作する」）で使う。毎回ペアリングが要るように
 * なるが、資格情報をどこにも書き残さないよりはよい。
 *
 * Kotlin 版の `MemoryBacking` は API 22 以下の端末専用だったが、iOS には
 * OS バージョンによる分岐点は無い。**Keychain の書き込みが実際に失敗した
 * 場合の受け皿**としてこちらを使う（`FluseKeychainStore.open()` を参照）。
 */
final class MemoryBacking: FluseBacking {
    let isPersistent = false

    private let lock = NSLock()
    private var values: [String: String] = [:]

    func getString(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func putString(_ key: String, _ value: String?) {
        lock.lock()
        defer { lock.unlock() }
        if let value = value, !value.isEmpty {
            values[key] = value
        } else {
            values.removeValue(forKey: key)
        }
    }

    func getInt(_ key: String, fallback: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let raw = values[key], let parsed = Int(raw) else { return fallback }
        return parsed
    }

    func putInt(_ key: String, _ value: Int) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = String(value)
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        values.removeAll()
    }
}

/**
 * `kSecClassGenericPassword` に置く。
 *
 * Kotlin 版の `PreferencesBacking`（`EncryptedSharedPreferences`）に相当する。
 * Android は「値を暗号化した上で、鍵自体を Android Keystore で守る」ために
 * `MasterKey` を組む必要があったが、iOS の Keychain は端末そのものが暗号化の
 * 境界であり、追加の鍵管理をアプリ側で組む必要が無い（OS が Secure Enclave /
 * デバイスパスコードで守る）。そのため Kotlin 版の `MasterKey.Builder` に
 * 相当する組み立てはここには無い。
 *
 * **値ごとに `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` を付ける。**
 * `deviceToken` は永続の資格情報であり、iCloud キーチェーン同期や
 * バックアップ経由で別の物理端末に渡ってしまうと「この端末で発行された
 * トークンが別端末でも通る」ことになり、設計 §6.1 の脅威モデル（LAN 上の
 * 第三者）とは別の経路で資格情報が漏れる。`ThisDeviceOnly` はバックアップ
 * からの復元では使えない属性で、これを避けられる。`AfterFirstUnlock`
 * （`WhenUnlocked` ではない）は、端末再起動後・初回ロック解除前に
 * バックグラウンドで再接続を試みても読めるようにするため
 * （Kotlin 版に対応する制約は無いが、iOS 固有の事情なのでここで判断する）。
 */
final class KeychainBacking: FluseBacking {
    let isPersistent = true

    /// Keychain の書き込みが実際に通るか確かめるためだけに使う鍵の接頭辞。
    ///
    /// **宣言ではなく実際に試す。** Keychain は OS バージョンに依らず常に
    /// 使えるはずだが、シミュレータや署名の無いテスト実行環境では実際には
    /// 書けないことがある。Kotlin 版が `Build.VERSION.SDK_INT` で事前判定
    /// するのに対し、iOS には対応する事前判定 API が無いため、ダミー値の
    /// 書き込み・読み出し・削除で判定する（`FluseKeychainStore.open()`）。
    static let probeKeyPrefix = "__fluse_probe__"

    private let service: String

    init(service: String) {
        self.service = service
    }

    func getString(_ key: String) -> String? {
        var query = baseQuery(account: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                logUnexpected(status, "読み出し", key)
            }
            return nil
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            // 値が壊れている（別形式で書かれた等）。**値そのものはログに
            // 出さない。** 何のキーで起きたかだけ残す。
            os_log(
                "Keychain の値を文字列として読めません（key=%{public}@）",
                log: FluseRuntimeCore.log,
                type: .error,
                key
            )
            return nil
        }
        return value
    }

    func putString(_ key: String, _ value: String?) {
        guard let value = value, !value.isEmpty else {
            deleteItem(key)
            return
        }
        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery(account: key) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            logUnexpected(updateStatus, "更新", key)
            return
        }

        var addQuery = baseQuery(account: key)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            logUnexpected(addStatus, "追加", key)
        }
    }

    func getInt(_ key: String, fallback: Int) -> Int {
        guard let raw = getString(key), let parsed = Int(raw) else { return fallback }
        return parsed
    }

    func putInt(_ key: String, _ value: Int) {
        putString(key, String(value))
    }

    func clear() {
        let status = SecItemDelete(baseQuery(account: nil) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            logUnexpected(status, "全消去", "*")
            return
        }
    }

    /// 実際に書き込めるか。[FluseKeychainStore.open] だけが使う。
    func canWrite() -> Bool {
        let probeKey = "\(Self.probeKeyPrefix)\(UUID().uuidString)"
        putString(probeKey, "probe")
        let readBack = getString(probeKey)
        deleteItem(probeKey)
        return readBack == "probe"
    }

    private func deleteItem(_ key: String) {
        let status = SecItemDelete(baseQuery(account: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            logUnexpected(status, "削除", key)
            return
        }
    }

    private func baseQuery(account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account = account {
            query[kSecAttrAccount as String] = account
        }
        return query
    }

    /// **値は載せない。** キー名とステータスコードだけで十分に切り分けられる。
    private func logUnexpected(_ status: OSStatus, _ operation: String, _ key: String) {
        os_log(
            "Keychain の%{public}@に失敗しました（key=%{public}@, status=%d）",
            log: FluseRuntimeCore.log,
            type: .error,
            operation,
            key,
            status
        )
    }
}

/**
 * 端末側に残す設定（設計 §2.2.5 / §6.1）。
 *
 * 移植元: `packages/fluse_runtime/android/src/main/kotlin/dev/fluse/runtime/FluseStore.kt`
 *
 * **`deviceToken` は永続の資格情報**で、盗まれれば以後のセッションにも
 * 繋がれる。平文のファイルには置かず Keychain（`kSecClassGenericPassword`）
 * を使う。`FluseConnectionStore`（`FluseConnection.swift`、Task 9.3 で用意
 * 済みの差し込み口）に適合させ、`FluseConnection.getOrCreate` にそのまま
 * 渡せる形にしてある。
 */
public final class FluseKeychainStore: FluseConnectionStore {
    /// Keychain 上のサービス名。Android 版の `FILE_NAME`（ファイル名）に
    /// 相当する識別子。
    static let service = "dev.fluse.runtime.store"

    private static let keyDeviceToken = "deviceToken"
    private static let keyLastHost = "lastHost"
    private static let keyLastPort = "lastPort"
    private static let keyDeviceId = "deviceId"

    /// ポート未設定を表す内部の番兵値。Kotlin 版の `NO_PORT` に相当するが、
    /// `FluseConnectionStore.lastPort` が `Int?` で表現できるため、この値は
    /// `FluseBacking` との往復にしか使わず外へは出さない。
    private static let noPort = -1

    /// 代替 deviceId の元にする乱数のバイト数。
    private static let fallbackIdBytes = 16

    private let backing: FluseBacking

    /// テストのために差し込む。Kotlin 版の `internal constructor` に相当し、
    /// `@testable import` からのみ届く。
    init(backing: FluseBacking) {
        self.backing = backing
    }

    /**
     * 端末のストアを開く。
     *
     * **Keychain が使えなければメモリへ落とす。** Kotlin 版は API レベルで
     * 事前に判定するが、iOS の Keychain には対応する事前判定 API が無いため
     * `KeychainBacking.canWrite()` で実際に書き込みを試す。落ちたことは
     * `isPersistent` が `false` になることで分かるようにしてあり、黙って
     * 落とすわけではない（呼び出し側が UI に出したければ出せる）。
     */
    public static func open() -> FluseKeychainStore {
        let keychain = KeychainBacking(service: service)
        if keychain.canWrite() {
            return FluseKeychainStore(backing: keychain)
        }
        os_log(
            "この端末では Keychain が使えません。起動のたびにペアリングが必要になります",
            log: FluseRuntimeCore.log,
            type: .error
        )
        return FluseKeychainStore(backing: MemoryBacking())
    }

    /// ディスクに残るか。残らない環境では毎回ペアリングが要る。
    public var isPersistent: Bool { backing.isPersistent }

    /// ペアリング済みなら値が入る。無ければ nil。
    public var deviceToken: String? {
        get { backing.getString(Self.keyDeviceToken) }
        set { backing.putString(Self.keyDeviceToken, newValue) }
    }

    /// 前回繋がったサーバのホスト。
    public var lastHost: String? {
        get { backing.getString(Self.keyLastHost) }
        set { backing.putString(Self.keyLastHost, newValue) }
    }

    /// 前回繋がったサーバのポート。未設定は nil。
    public var lastPort: Int? {
        get {
            let value = backing.getInt(Self.keyLastPort, fallback: Self.noPort)
            return value == Self.noPort ? nil : value
        }
        set {
            backing.putInt(Self.keyLastPort, newValue ?? Self.noPort)
        }
    }

    /**
     * `identifierForVendor` が取れない端末のための代替 ID。
     *
     * **端末ごとに違う値でなければならない。** 取れない端末で同じ値に
     * 落とすと、別々の端末がサーバから見て1台に見え、片方の登録が
     * もう片方を上書きする（Kotlin 版の `fallbackDeviceId()` と同じ理由）。
     */
    public func fallbackDeviceId() -> String {
        if let existing = backing.getString(Self.keyDeviceId), !existing.isEmpty {
            return existing
        }
        let generated = Self.generateFallbackDeviceId()
        backing.putString(Self.keyDeviceId, generated)
        return generated
    }

    /// ペアリング済みか。
    public func hasDeviceToken() -> Bool {
        !(deviceToken?.isEmpty ?? true)
    }

    /// 前回の接続先が分かるか。
    public func hasLastServer() -> Bool {
        !(lastHost?.isEmpty ?? true) && lastPort != nil
    }

    /// 登録を消す。ペアリングからやり直す時に使う。
    public func clear() {
        backing.clear()
    }

    /// 予測されにくい代替 ID を作る。
    ///
    /// Kotlin 版は `SecureRandom` を使う。iOS 側では同じ役割を持つ
    /// Security フレームワークの `SecRandomCopyBytes`（CSPRNG）を使う。
    static func generateFallbackDeviceId() -> String {
        var bytes = [UInt8](repeating: 0, count: fallbackIdBytes)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        // **失敗を握り潰さない。** ここで乱数が取れないのは端末の暗号
        // サブシステムそのものが壊れている状況で、フォールバックの意味が
        // 無くなる（同じ固定値に倒すと「端末ごとに違う」保証が崩れる）。
        precondition(status == errSecSuccess, "セキュアな乱数の生成に失敗しました（status=\(status)）")
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(FluseDeviceIdentity.deviceIdLength))
    }
}

extension FluseKeychainStore: CustomStringConvertible {
    /// **トークンは含めない。** 例外文やログに混ざると漏れる
    /// （Kotlin 版の `toString()` と同じ判断）。
    public var description: String {
        "FluseKeychainStore(paired=\(hasDeviceToken()), persistent=\(isPersistent))"
    }
}
