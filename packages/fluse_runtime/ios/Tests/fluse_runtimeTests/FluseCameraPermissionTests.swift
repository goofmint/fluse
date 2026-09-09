import XCTest

@testable import fluse_runtime

/// `FluseCameraPermission.decide` の判断だけを、`AVFoundation` に触れずに確かめる。
final class FluseCameraPermissionTests: XCTestCase {
    func testStartsCameraWhenHardwarePresentAndAuthorized() {
        XCTAssertEqual(
            .startCamera,
            FluseCameraPermission.decide(hasCameraHardware: true, authorization: .authorized)
        )
    }

    func testRequestsPermissionWhenHardwarePresentAndNotDetermined() {
        XCTAssertEqual(
            .requestPermission,
            FluseCameraPermission.decide(hasCameraHardware: true, authorization: .notDetermined)
        )
    }

    func testFallsBackToManualInputWhenDenied() {
        XCTAssertEqual(
            .useManualInput,
            FluseCameraPermission.decide(hasCameraHardware: true, authorization: .denied)
        )
    }

    /// シミュレータのように、ハードウェアが無ければ権限の状態を見る意味が無い。
    func testFallsBackToManualInputWhenNoHardwareRegardlessOfAuthorization() {
        XCTAssertEqual(
            .useManualInput,
            FluseCameraPermission.decide(hasCameraHardware: false, authorization: .authorized)
        )
        XCTAssertEqual(
            .useManualInput,
            FluseCameraPermission.decide(hasCameraHardware: false, authorization: .notDetermined)
        )
        XCTAssertEqual(
            .useManualInput,
            FluseCameraPermission.decide(hasCameraHardware: false, authorization: .denied)
        )
    }
}
