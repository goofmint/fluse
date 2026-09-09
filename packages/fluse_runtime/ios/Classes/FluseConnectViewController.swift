#if canImport(UIKit)
import AVFoundation
import UIKit

/**
 * ペアリング画面（設計 §2.2.5）。
 *
 * 移植元: `packages/fluse_runtime/android/src/main/kotlin/dev/fluse/runtime/FluseConnectActivity.kt`
 * + `FluseQrAnalyzer.kt` に相当する新規実装。Android は CameraX + ZXing が
 * 必要だったが、iOS は `AVFoundation` の `AVCaptureSession` +
 * `AVCaptureMetadataOutput`（`.qr`）だけで足りる。ZXing 相当のライブラリは
 * 使わない。
 *
 * **判断は持たない。** 「読み取った文字列やボタン操作をどう扱うか」は
 * すべて `FluseConnectPresenter` に委ね、ここは
 *   1. `AVCaptureSession` の組み立てとカメラ権限の要求
 *   2. 返ってきた `FluseConnectAction` の実行（ラベルの更新・面の切り替え・
 *      `FluseConnection` への接続開始）
 * だけを行う。`swift test` は macOS で走り `AVFoundation` のカメラ機能に
 * 触れられないため、判断側（`FluseConnectPresenter` / `FluseCameraPermission`）
 * を分けてそちらだけを単体テストの対象にしてある。このファイル自体は
 * 実機・シミュレータでの動作確認が必要（このタスクでは未確認）。
 */
final class FluseConnectViewController: UIViewController {
    private static let backgroundColor = UIColor(red: 0x12 / 255, green: 0x12 / 255, blue: 0x12 / 255, alpha: 1)
    private static let textColor = UIColor.white

    private let appInfo: FluseAppInfo
    private let device: FluseDeviceInfo
    private let store: FluseConnectionStore
    private let presenter: FluseConnectPresenter
    private let onFinished: () -> Void

    // ---------------------------------------------------------------- スキャン面

    private let scanContainerView = UIView()
    private let previewContainerView = UIView()
    private let scanMessageLabel = UILabel()
    private let manualSwitchButton = UIButton(type: .system)

    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var captureSession: AVCaptureSession?
    private var metadataOutput: AVCaptureMetadataOutput?

    /// カメラの起動・停止は `AVCaptureSession` の作法に従い、メインスレッド
    /// から外す（Apple のドキュメントが推奨する形。Android 版の
    /// `analysisExecutor` に相当）。
    private let sessionQueue = DispatchQueue(label: "dev.fluse.runtime.connect.camera")

    // ---------------------------------------------------------------- 手入力面

    private let manualScrollView = UIScrollView()
    private let manualStack = UIStackView()
    private let manualMessageLabel = UILabel()
    private let hostField = UITextField()
    private let portField = UITextField()
    private let tokenField = UITextField()
    private let connectButton = UIButton(type: .system)

    // ---------------------------------------------------------------- 接続

    /// 受理された `FluseConnection`。画面を閉じるときに listener を外すために持つ。
    private var connection: FluseConnection?

    init(
        appInfo: FluseAppInfo,
        device: FluseDeviceInfo,
        store: FluseConnectionStore,
        onFinished: @escaping () -> Void
    ) {
        self.appInfo = appInfo
        self.device = device
        self.store = store
        self.presenter = FluseConnectPresenter(appInfo: appInfo)
        self.onFinished = onFinished
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("コードから生成しない（ライブラリ内で組み立てる画面のため）")
    }

    deinit {
        // **listener を外す。** 画面を握ったままだと、以後の接続の通知が
        // 届き続け、このインスタンスが解放されない
        // （`FluseConnectActivity.onDestroy` と同じ理由）。
        connection?.removeListener(self)
        // 通常は `.finish` / `switchToManual` の経路で既に `nil` になって
        // いるはずだが、その他の経路で破棄された時のための保険。
        // メインスレッドを塞がないよう、停止は `sessionQueue` に投げる
        // （`self` を捕まえない。deinit の後まで生き延びさせないため）。
        if let session = captureSession {
            sessionQueue.async { session.stopRunning() }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Self.backgroundColor
        buildScanPane()
        buildManualPane()
        manualScrollView.isHidden = true
        decideCameraAvailability()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = previewContainerView.bounds
    }

    // ------------------------------------------------------------------ 組み立て

    private func buildScanPane() {
        scanContainerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scanContainerView)

        previewContainerView.backgroundColor = .black
        previewContainerView.translatesAutoresizingMaskIntoConstraints = false
        scanContainerView.addSubview(previewContainerView)

        scanMessageLabel.text = FluseConnectStrings.scanHint
        scanMessageLabel.textColor = Self.textColor
        scanMessageLabel.numberOfLines = 0
        scanMessageLabel.translatesAutoresizingMaskIntoConstraints = false
        scanContainerView.addSubview(scanMessageLabel)

        manualSwitchButton.setTitle(FluseConnectStrings.manualSwitchTitle, for: .normal)
        manualSwitchButton.addTarget(self, action: #selector(handleSwitchToManualTapped), for: .touchUpInside)
        manualSwitchButton.translatesAutoresizingMaskIntoConstraints = false
        scanContainerView.addSubview(manualSwitchButton)

        NSLayoutConstraint.activate([
            scanContainerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scanContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scanContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scanContainerView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            previewContainerView.topAnchor.constraint(equalTo: scanContainerView.topAnchor),
            previewContainerView.leadingAnchor.constraint(equalTo: scanContainerView.leadingAnchor),
            previewContainerView.trailingAnchor.constraint(equalTo: scanContainerView.trailingAnchor),

            scanMessageLabel.topAnchor.constraint(equalTo: previewContainerView.bottomAnchor, constant: 16),
            scanMessageLabel.leadingAnchor.constraint(equalTo: scanContainerView.leadingAnchor, constant: 16),
            scanMessageLabel.trailingAnchor.constraint(equalTo: scanContainerView.trailingAnchor, constant: -16),

            manualSwitchButton.topAnchor.constraint(equalTo: scanMessageLabel.bottomAnchor, constant: 8),
            manualSwitchButton.leadingAnchor.constraint(equalTo: scanContainerView.leadingAnchor, constant: 16),
            manualSwitchButton.trailingAnchor.constraint(equalTo: scanContainerView.trailingAnchor, constant: -16),
            manualSwitchButton.bottomAnchor.constraint(equalTo: scanContainerView.bottomAnchor, constant: -16),
        ])
    }

    private func buildManualPane() {
        manualScrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(manualScrollView)

        manualStack.axis = .vertical
        manualStack.spacing = 12
        manualStack.translatesAutoresizingMaskIntoConstraints = false
        manualScrollView.addSubview(manualStack)

        manualMessageLabel.text = FluseConnectStrings.manualHint
        manualMessageLabel.textColor = Self.textColor
        manualMessageLabel.numberOfLines = 0

        [hostField, portField, tokenField].forEach { field in
            field.borderStyle = .roundedRect
            field.textColor = Self.textColor
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
        }
        hostField.placeholder = FluseConnectStrings.hostPlaceholder
        portField.placeholder = FluseConnectStrings.portPlaceholder
        portField.keyboardType = .numberPad
        tokenField.placeholder = FluseConnectStrings.tokenPlaceholder

        connectButton.setTitle(FluseConnectStrings.connectButtonTitle, for: .normal)
        connectButton.addTarget(self, action: #selector(handleConnectTapped), for: .touchUpInside)

        [manualMessageLabel, hostField, portField, tokenField, connectButton].forEach {
            manualStack.addArrangedSubview($0)
        }

        NSLayoutConstraint.activate([
            manualScrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            manualScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            manualScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            manualScrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            manualStack.topAnchor.constraint(equalTo: manualScrollView.topAnchor, constant: 16),
            manualStack.leadingAnchor.constraint(equalTo: manualScrollView.leadingAnchor, constant: 16),
            manualStack.trailingAnchor.constraint(equalTo: manualScrollView.trailingAnchor, constant: -16),
            manualStack.bottomAnchor.constraint(equalTo: manualScrollView.bottomAnchor, constant: -16),
            manualStack.widthAnchor.constraint(equalTo: manualScrollView.widthAnchor, constant: -32),
        ])
    }

    // -------------------------------------------------------------- カメラ権限

    private func decideCameraAvailability() {
        let hasHardware = AVCaptureDevice.default(for: .video) != nil
        let authorization = Self.authorization(from: AVCaptureDevice.authorizationStatus(for: .video))

        switch FluseCameraPermission.decide(hasCameraHardware: hasHardware, authorization: authorization) {
        case .startCamera:
            startCameraSession()
        case .requestPermission:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if granted {
                        self.startCameraSession()
                    } else {
                        self.apply(self.presenter.cameraUnavailable())
                    }
                }
            }
        case .useManualInput:
            apply(presenter.cameraUnavailable())
        }
    }

    /// `AVAuthorizationStatus` を `FluseCameraAuthorization` へ均す。
    ///
    /// **ここでしか `AVFoundation` の型に触らない。** 判断そのもの
    /// （`FluseCameraPermission.decide`）は `AVFoundation` を知らない。
    private static func authorization(from status: AVAuthorizationStatus) -> FluseCameraAuthorization {
        switch status {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    // ------------------------------------------------------------------ カメラ

    private func startCameraSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            let session = AVCaptureSession()
            session.beginConfiguration()
            // **`defer` で閉じない。** `defer` は関数を抜ける時に走るので、
            // 下の `startRunning()` が設定ブロックを開いたままの状態で
            // 呼ばれてしまう。この順序だと `NSGenericException` でアプリが
            // 落ちる。成功経路・失敗経路のどちらでも、先に明示的に
            // 閉じてから次へ進む。
            var committed = false
            func commit() {
                if !committed {
                    committed = true
                    session.commitConfiguration()
                }
            }

            guard
                let device = AVCaptureDevice.default(for: .video),
                let input = try? AVCaptureDeviceInput(device: device),
                session.canAddInput(input)
            else {
                commit()
                self.failToStartCamera()
                return
            }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                commit()
                self.failToStartCamera()
                return
            }
            // **出力を追加した後でなければ `metadataObjectTypes` を設定できない。**
            // 追加前に触ると `availableMetadataObjectTypes` が空で例外になる。
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            guard output.availableMetadataObjectTypes.contains(.qr) else {
                commit()
                self.failToStartCamera()
                return
            }
            // QR だけに絞る。Android の `FluseQrAnalyzer` が
            // `DecodeHintType.POSSIBLE_FORMATS` を QR だけにするのと同じ理由。
            output.metadataObjectTypes = [.qr]

            // **設定を閉じてから走らせる。** 開いたまま `startRunning()` を
            // 呼ぶと `NSGenericException` になる。
            commit()

            // `startRunning()` はメインスレッドで呼ばないのが作法
            // （Apple のドキュメントの推奨）。ここまではまだローカル変数
            // だけを触っているので、他スレッドとの競合は無い。
            session.startRunning()

            // **ここから先は必ずメインスレッドで。** `captureSession` /
            // `metadataOutput` / `previewLayer` は `stopCameraSession()` や
            // `viewDidLayoutSubviews` からもメインスレッドで読み書きされる
            // ため、バックグラウンドから直接書き込むとデータ競合になる。
            DispatchQueue.main.async {
                self.captureSession = session
                self.metadataOutput = output
                self.attachPreviewLayer(session: session)
            }
        }
    }

    private func failToStartCamera() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.apply(self.presenter.cameraUnavailable())
        }
    }

    private func attachPreviewLayer(session: AVCaptureSession) {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = previewContainerView.bounds
        previewContainerView.layer.insertSublayer(layer, at: 0)
        previewLayer = layer
    }

    private func stopCameraSession() {
        guard let session = captureSession else { return }
        sessionQueue.async { session.stopRunning() }
        captureSession = nil
        metadataOutput = nil
        previewLayer?.removeFromSuperlayer()
        previewLayer = nil
    }

    // ---------------------------------------------------------------- 操作

    @objc private func handleSwitchToManualTapped() {
        apply(presenter.switchToManualRequested())
    }

    @objc private func handleConnectTapped() {
        apply(
            presenter.manualSubmitted(
                host: hostField.text ?? "",
                port: portField.text ?? "",
                token: tokenField.text ?? ""
            )
        )
    }

    // -------------------------------------------------------- Action の実行

    private func apply(_ actions: [FluseConnectAction]) {
        actions.forEach(apply)
    }

    private func apply(_ action: FluseConnectAction) {
        switch action {
        case let .showScanMessage(message):
            scanMessageLabel.text = message
        case let .showManualMessage(message):
            manualMessageLabel.text = message
        case let .switchToManual(message):
            stopCameraSession()
            scanContainerView.isHidden = true
            manualScrollView.isHidden = false
            manualMessageLabel.text = message
        case let .beginConnect(request):
            beginConnect(request)
        case .resumeScanning:
            // **ここでは何もしない。** Android 版は ZXing の
            // `AtomicBoolean`（`FluseQrAnalyzer.resume()`）を明示的に戻す
            // 必要があったが、iOS 側の「連続読み取りの抑止」は
            // `FluseConnectPresenter` の `connecting` フラグだけで
            // 表現されており、`AVCaptureMetadataOutput` 側は常に稼働し続けて
            // 良い（`failed()` が `connecting` を戻せば、次のコールバックから
            // 自然に再び処理される）。
            break
        case .finish:
            // **カメラを明示的に止める。** `AVCaptureMetadataOutput` の
            // delegate は `self`（強参照）なので、`captureSession` を
            // 持ったままだと `self → captureSession → metadataOutput →
            // delegate(self)` の環になり、`window` 側の参照を切っただけでは
            // 解放されない。ここで `stopCameraSession()` を呼び、
            // `captureSession` / `metadataOutput` への参照を切ってから
            // 抜ける（QR 経由で受理された時は `switchToManual` を経由
            // しないため、ここでも同じ後始末が必要）。
            stopCameraSession()
            connection?.removeListener(self)
            onFinished()
        }
    }

    private func beginConnect(_ request: FluseConnectRequest) {
        let connection = FluseConnection.getOrCreate(store: store, device: device, appInfo: appInfo)
        connection.addListener(self)
        self.connection = connection
        // **接続より先に届いた分を渡す。** 渡さないと、受理できたのに
        // 送るものが無い状態になり、初回の vmServiceReady が落ちる
        // （`FluseInitProvider.kt` の `ConnectingStartupHandler.reconnect` と同じ理由）。
        if let pending = FluseRuntimeCore.latestVmServiceUri {
            connection.vmServiceReady(pending)
        }
        // **`connect()` は例外を投げない（iOS 版の実装）。** Android 版の
        // `connect()` は URI 構築の失敗で例外を投げることがあり
        // `FluseConnectActivity.accept()` は try/catch していたが、iOS の
        // `FluseEndpoint.webSocketUrl()` は文字列組み立てのみで失敗しない
        // ため、対応する catch 節（`presenter.connectFailedToStart()` を
        // 呼ぶ経路）はここには無い。
        connection.connect(endpoint: request.endpoint(), pairingToken: request.pairingToken)
    }
}

// ---------------------------------------------------- AVCaptureMetadataOutputObjectsDelegate

extension FluseConnectViewController: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard
            let code = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
            let text = code.stringValue
        else {
            return
        }
        apply(presenter.scanned(text))
    }
}

// ---------------------------------------------------------- FluseConnectionListener

extension FluseConnectViewController: FluseConnectionListener {
    // `FluseConnection` は「メインスレッドへの自動ホップは行わない」契約
    // （`FluseConnection.swift` のコメント参照）。ここで UI に触る前に
    // 必ず戻す。

    func onConnected(sessionId: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.apply(self.presenter.connected(sessionId: sessionId))
        }
    }

    func onRejected(code: String, message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.apply(self.presenter.rejected(code: code, message: message))
        }
    }

    func onNeedsPairing(reason: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.apply(self.presenter.needsPairing(reason: reason))
        }
    }

    func onCleartextBlocked(
        host: String,
        message: String,
        certainty: FluseCleartextCertainty
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.apply(self.presenter.cleartextBlocked(message: message, certainty: certainty))
        }
    }

    func onDisconnected() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.apply(self.presenter.disconnected())
        }
    }

    func onMessage(_ message: FluseMessage) {}
}
#endif
