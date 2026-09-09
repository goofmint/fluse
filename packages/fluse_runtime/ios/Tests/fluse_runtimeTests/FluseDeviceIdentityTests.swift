import XCTest

@testable import fluse_runtime

/// `FluseDeviceIdentity` の platform 非依存な計算（ハッシュ・代替 ID への
/// 委譲）だけを見る。`identifierForVendor` の取得そのものは UIKit が要る
/// ため対象外（`FluseDeviceIdentity.swift` のヘッダ参照）。
///
/// 移植元: `packages/fluse_runtime/android/src/test/kotlin/dev/fluse/runtime/DeviceIdentityTest.kt`
///
/// **`deviceName` 系のテストは移植しない。** Kotlin 版は
/// `Build.MANUFACTURER` + `Build.MODEL` を組む `deviceName(manufacturer:model:)`
/// を持つが、iOS には対応する「メーカー名」の概念が無く、この Issue
/// （#95）の要求（端末識別の計算そのもの）にも含まれないため
/// `FluseDeviceIdentity` に同種の関数を追加していない
/// （`FluseDeviceIdentity.swift` のヘッダ参照）。該当する3ケース
/// （`deviceName はメーカーと型番をつなぐ` / `型番がメーカー名で始まるなら重ねない` /
/// `片方が空でも形になる`）はこの理由で対応するテストが無い。
final class FluseDeviceIdentityTests: XCTestCase {
    func testSameVendorIdProducesSameDeviceId() {
        // 再起動のたびに変わると、サーバ側の登録が積み上がる。
        let id = FluseDeviceIdentity.hashVendorId("a1b2c3d4-e5f6-4071-8000-000000000001")

        XCTAssertEqual(id, FluseDeviceIdentity.hashVendorId("a1b2c3d4-e5f6-4071-8000-000000000001"))
    }

    func testDifferentVendorIdProducesDifferentDeviceId() {
        XCTAssertNotEqual(
            FluseDeviceIdentity.hashVendorId("a1b2c3d4-e5f6-4071-8000-000000000001"),
            FluseDeviceIdentity.hashVendorId("a1b2c3d4-e5f6-4071-8000-000000000002")
        )
    }

    func testDeviceIdIsSixteenHexDigits() {
        let id = FluseDeviceIdentity.hashVendorId("a1b2c3d4-e5f6-4071-8000-000000000001")

        XCTAssertEqual(FluseDeviceIdentity.deviceIdLength, id.count)
        XCTAssertTrue(id.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }, id)
    }

    func testOriginalVendorIdIsNotContained() {
        // identifierForVendor は他のアプリとの突き合わせに使える。そのまま送らない。
        let vendorId = "a1b2c3d4-e5f6-4071-8000-000000000001"

        XCTAssertFalse(FluseDeviceIdentity.hashVendorId(vendorId).contains(vendorId))
    }

    func testMissingVendorIdUsesFallback() {
        // nil を hashVendorId にそのまま通すと、取れない端末どうしが
        // 同じ deviceId になる。サーバから見て1台に見え、片方の登録が
        // 上書きされる。
        let store = FluseKeychainStore(backing: MemoryBacking())

        let id = FluseDeviceIdentity.deviceId(vendorId: nil) { store.fallbackDeviceId() }

        XCTAssertEqual(FluseDeviceIdentity.deviceIdLength, id.count)
        XCTAssertNotEqual(FluseDeviceIdentity.hashVendorId(""), id)
    }

    func testEmptyVendorIdUsesFallbackToo() {
        // 空文字は「取れなかった」と同じ扱いにする。Android の
        // ANDROID_ID が空文字を返す状況と同じ判断（Kotlin 版の
        // `androidId.isNullOrEmpty()` に相当）。
        let store = FluseKeychainStore(backing: MemoryBacking())

        let id = FluseDeviceIdentity.deviceId(vendorId: "") { store.fallbackDeviceId() }

        XCTAssertEqual(store.fallbackDeviceId(), id)
    }

    func testPresentVendorIdIsHashedDirectly() {
        let vendorId = "a1b2c3d4-e5f6-4071-8000-000000000001"
        var fallbackCalled = false

        let id = FluseDeviceIdentity.deviceId(vendorId: vendorId) {
            fallbackCalled = true
            return "should-not-be-used"
        }

        XCTAssertEqual(FluseDeviceIdentity.hashVendorId(vendorId), id)
        XCTAssertFalse(fallbackCalled, "vendorId が取れているのに fallback を呼んでいる")
    }
}
