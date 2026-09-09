import XCTest

@testable import fluse_runtime

/// `FluseKeychainStore` が `MemoryBacking` の上で Kotlin 版と同じ挙動に
/// なるかを見る。
///
/// 移植元: `packages/fluse_runtime/android/src/test/kotlin/dev/fluse/runtime/FluseStoreTest.kt`
/// ケースは減らさず、同じ入力・同じ期待値で移植する。
///
/// **実 Keychain（`KeychainBacking`）には触らない。** macOS 上の
/// `swift test` は署名やサンドボックスの都合で Keychain API が使えないこと
/// があるため（Issue #95 の制約）、テストは常に `FluseBacking` を
/// `MemoryBacking` に差し替えて行う。実 Keychain 経路（`open()` が
/// 失敗時にメモリへ落ちること）はコード上の分岐として用意してあるが、
/// この環境からは検証できない。
final class FluseKeychainStoreTests: XCTestCase {
    private func store() -> FluseKeychainStore {
        FluseKeychainStore(backing: MemoryBacking())
    }

    /// テスト用のトークン。
    ///
    /// **リテラルで書かない。** ダミーであっても、資格情報の形をした
    /// 文字列がリポジトリに残ると本物と見分けが付かない
    /// （`FluseRuntimeCoreTests.authCode` と同じ方針）。
    private func token() -> String {
        (0..<32)
            .map { _ in String(format: "%01x", Int.random(in: 0...15)) }
            .joined()
    }

    func testFallbackDeviceIdDoesNotChangeOnceGenerated() {
        // 起動のたびに変わると、サーバ側の登録が積み上がる。
        let store = store()

        XCTAssertEqual(store.fallbackDeviceId(), store.fallbackDeviceId())
    }

    func testFallbackDeviceIdDiffersPerStore() {
        // 同じ値に落ちると、別々の端末が1台に見える。
        XCTAssertNotEqual(store().fallbackDeviceId(), store().fallbackDeviceId())
    }

    func testFallbackDeviceIdIsSixteenHexDigits() {
        // ANDROID_ID 相当（`identifierForVendor`）由来の deviceId と同じ形にしておく。
        let id = store().fallbackDeviceId()

        XCTAssertEqual(FluseDeviceIdentity.deviceIdLength, id.count)
        XCTAssertTrue(id.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }, id)
    }

    func testWritingEmptyStringClearsDeviceToken() {
        // 空文字が残ると hasDeviceToken() が true になってしまう。
        let store = store()
        store.deviceToken = token()

        store.deviceToken = ""

        XCTAssertNil(store.deviceToken)
        XCTAssertFalse(store.hasDeviceToken())
    }

    func testNeedsBothTokenAndServerToReconnect() {
        let store = store()
        store.deviceToken = token()

        XCTAssertFalse(store.hasLastServer())

        store.lastHost = "192.168.1.2"
        store.lastPort = 8080

        XCTAssertTrue(store.hasLastServer())
    }

    func testMissingPortMeansNoLastServer() {
        // ホストだけでは繋ぎようが無い。
        let store = store()
        store.lastHost = "192.168.1.2"

        XCTAssertNil(store.lastPort)
        XCTAssertFalse(store.hasLastServer())
    }

    func testClearResetsEverythingToDefaults() {
        // **ポートが残ると危ない。** ホストだけ入れ直した時に、
        // 前のポートと組み合わさって古い接続先へ繋ぎに行く。
        let store = store()
        store.deviceToken = token()
        store.lastHost = "192.168.1.2"
        store.lastPort = 8080

        store.clear()

        XCTAssertNil(store.deviceToken)
        XCTAssertNil(store.lastHost)
        XCTAssertNil(store.lastPort)
        XCTAssertFalse(store.hasDeviceToken())
        XCTAssertFalse(store.hasLastServer())
    }

    func testDescriptionDoesNotContainToken() {
        // 例外文やログに混ざると漏れる。
        let store = store()
        let value = token()
        store.deviceToken = value

        XCTAssertFalse(store.description.contains(value), store.description)
    }

    func testMemoryOnlyBackingIsNotPersistent() {
        // 平文で残すより、起動のたびにペアリングさせる方がよい。
        XCTAssertFalse(store().isPersistent)
    }
}
