import Foundation
import os.log

/**
 * サーバとの唯一の接続（設計 §2.2.5）。
 *
 * 移植元: `packages/fluse_runtime/android/src/main/kotlin/dev/fluse/runtime/FluseConnection.kt`
 *
 * **Application スコープに置く。** Hot Restart は Dart isolate だけを
 * 作り直し、プロセスは生きたままなので、接続を張り直さずに済ませられる
 * （設計 §10-6）。Kotlin 版は `Application` に紐づく `companion object` の
 * `instance` として持たせているが、iOS 側には `Application` に相当する
 * ライフサイクルの節目が言語レベルには無いため、ここでは型（`static`）に
 * 持たせることで同じ「プロセスが生きている限り生き続ける」性質を再現する。
 * `UIApplicationDelegate` からの実際の配線（Task 9.1〜9.3 の後続）はこの
 * PR の範囲外。
 *
 * **並行処理は `NSLock` で写す。** Kotlin の `synchronized(lock)` /
 * `@Volatile` に相当する。Kotlin 版の `synchronized` ブロックはどこも
 * 入れ子になっていないため、再入不可の `NSLock` で問題なく等価に書ける。
 *
 * **メインスレッドへの自動ホップは行わない。** Kotlin 版がしていないため、
 * ここで足すとスレッドの飛び方が変わり、パリティが崩れる。呼び出し側
 * （UI 層）が必要ならメインスレッドへ戻すこと。
 *
 * **OS 依存物はこの PR では実装しない。** `FluseStore`（実ストレージ）・
 * `DeviceIdentity`（ANDROID_ID 相当の端末識別子取得）・
 * `FluseCleartext`（`ws://` の事前許可判定）・プラグインとしての実配線は
 * すべて後続チケットの対象。ここでは `FluseConnectionStore` /
 * `FluseDeviceInfo` という差し込み口だけを用意し、呼び出し側が組み立てた
 * 値を渡す形にしてある。
 */
public final class FluseConnection {
    // ---------------------------------------------------------- シングルトン

    private static let instanceLock = NSLock()
    private static var storedInstance: FluseConnection?

    /// Application スコープの唯一のインスタンス。
    public static var instance: FluseConnection? {
        instanceLock.lock()
        defer { instanceLock.unlock() }
        return storedInstance
    }

    /**
     * 作るか、既にあればそれを返す。
     *
     * **作り直さない。** Hot Restart のたびに新しくすると、生きている
     * 接続を捨てて張り直すことになる。
     *
     * Kotlin 版は `Application` と `FluseStore` から `FluseDeviceInfo` /
     * `FluseAppInfo` を自分で組み立てるが（`FluseDeviceInfo.of` /
     * `FluseAppInfo.load`）、iOS 側では端末識別子の取得や `Bundle` からの
     * 読み込みをこの PR で扱わないため、呼び出し側が組み立てた値を
     * そのまま受け取る。
     */
    public static func getOrCreate(
        store: FluseConnectionStore,
        device: FluseDeviceInfo,
        appInfo: FluseAppInfo
    ) -> FluseConnection {
        instanceLock.lock()
        defer { instanceLock.unlock() }
        if let existing = storedInstance {
            return existing
        }
        let created = FluseConnection(store: store, device: device, appInfo: appInfo)
        storedInstance = created
        return created
    }

    /// テストのために差し替える。
    static func install(_ connection: FluseConnection?) {
        instanceLock.lock()
        defer { instanceLock.unlock() }
        storedInstance = connection
    }

    /// 起動時に一度使うだけなので単一のキューで足りる。
    private static let defaultScheduler: RetryScheduler = DispatchRetryScheduler()

    // -------------------------------------------------------------- 依存先

    private let store: FluseConnectionStore
    private let device: FluseDeviceInfo
    private let appInfo: FluseAppInfo
    private let socketFactory: FluseSocketFactory
    private let scheduler: RetryScheduler
    private let backoff: FluseBackoff

    /// テストからは直接この初期化子を使ってフェイクを差し込む
    /// （Kotlin 版の `internal constructor` に相当）。
    init(
        store: FluseConnectionStore,
        device: FluseDeviceInfo,
        appInfo: FluseAppInfo,
        socketFactory: FluseSocketFactory = URLSessionFluseSocketFactory(),
        scheduler: RetryScheduler = FluseConnection.defaultScheduler,
        backoff: FluseBackoff = FluseBackoff()
    ) {
        self.store = store
        self.device = device
        self.appInfo = appInfo
        self.socketFactory = socketFactory
        self.scheduler = scheduler
        self.backoff = backoff
    }

    // ---------------------------------------------------------------- 状態

    private let lock = NSLock()

    /// 繋ぎ先。`connect` が決める。
    private var endpoint: FluseEndpoint?

    /**
     * 初回ペアリングのトークン。
     *
     * **`deviceToken` と同時には送れない。** サーバは両方載った `hello` を
     * 誤りとして断る。
     */
    private var pairingToken: String?

    private var socket: FluseSocket?

    /**
     * 今の接続の世代。
     *
     * **予約した再接続は取り消せない。** `connect` や `stop` で状況が
     * 変わった後に古い予約が動くと、生きているソケットを置き換えて
     * 二重のセッションになる。世代を見て、古い分は捨てる。
     *
     * 遅れて届くコールバックにも同じ番号を持たせてある。閉じた直後の
     * 通知が新しい接続の状態を消してしまうのを防ぐため。
     */
    private var generation = 0

    /// 止めたら再接続しない。`connect` を呼び直すまで動かない。
    private var stopped = true

    /// `accept` を受け取った後だけ値が入る。
    private var sessionId: String?

    /// `accept` が指定した heartbeat の間隔。診断のために持つ。
    public private(set) var heartbeatIntervalMs: Int64 = 0

    /**
     * Dart から受け取った VM Service の URI。
     *
     * **接続前に届くことがある。** `flusePreviewMain` はアプリの起動と
     * 並行に走るため、`accept` より先に来る。受理できるまで持っておく。
     */
    private var pendingVmServiceUri: String?

    /// 今のセッションで送り終えた URI。同じ値なら送り直さない。
    private var sentVmServiceUri: String?

    /**
     * 出来事を受け取る面々。
     *
     * **1つに絞れない。** ペアリング画面・エラーオーバーレイ・バッジが
     * 同時に見ている。1枠にすると、後から入った側が前の側を追い出す。
     *
     * Kotlin 版は `CopyOnWriteArraySet` を使い、参照の同一性で重複を
     * 弾いている（リスナー側で `equals` を override していない前提）。
     * ここでは配列 + `NSLock` + `===` 比較で同じ意味を再現する。通知の
     * たびにスナップショットを取ってから呼ぶ点も揃えてある（通知中に
     * 別スレッドから増減しても取りこぼしたり二重に呼んだりしない）。
     */
    private let listenersLock = NSLock()
    private var listeners: [FluseConnectionListener] = []

    public func addListener(_ listener: FluseConnectionListener) {
        listenersLock.lock()
        defer { listenersLock.unlock() }
        if !listeners.contains(where: { $0 === listener }) {
            listeners.append(listener)
        }
    }

    public func removeListener(_ listener: FluseConnectionListener) {
        listenersLock.lock()
        defer { listenersLock.unlock() }
        listeners.removeAll { $0 === listener }
    }

    private func notifyListeners(_ action: (FluseConnectionListener) -> Void) {
        listenersLock.lock()
        let snapshot = listeners
        listenersLock.unlock()
        snapshot.forEach(action)
    }

    /// 受理済みか。
    public var isAuthenticated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessionId != nil
    }

    /**
     * 繋ぎに行く。
     *
     * `pairingToken` は QR から来た初回だけ渡す。2回目以降は保存済みの
     * `deviceToken` を使う。
     *
     * **Kotlin 版にあった `FluseCleartext.isPermitted` の事前チェックは
     * ここには無い。** Android は `NetworkSecurityPolicy` で `ws://` の
     * 可否を事前に尋ねられるが、iOS の ATS（App Transport Security）には
     * 対応する事前問い合わせ API が無く、実際に繋ぎに行って初めて
     * `URLError` として失敗が分かる（受動判定）。この判定は設計 §10-4 の
     * 後続チケットの対象とし、ここでは行わない。塞がれている場合も
     * 特別扱いせず、他の接続失敗と同じく `onDisconnected` の経路で
     * バックオフ再接続に入る。`FluseConnectionListener.onCleartextBlocked`
     * は Kotlin とインターフェースの形だけ揃えてあるが、この PR では
     * どこからも呼ばれない。
     */
    public func connect(endpoint: FluseEndpoint, pairingToken: String? = nil) {
        lock.lock()
        closeSocketLocked(reason: "繋ぎ直します")
        self.endpoint = endpoint
        self.pairingToken = pairingToken
        stopped = false
        backoff.reset()
        // 進めた後の番号で開く。前置でないと1つ前の世代を渡してしまう。
        generation += 1
        let target = generation
        lock.unlock()
        openSocket(forGeneration: target)
    }

    /// 止める。以後は再接続しない。
    public func stop() {
        lock.lock()
        stopped = true
        // 世代を進めて、予約済みの再接続と遅れて届く通知を無効にする。
        generation += 1
        closeSocketLocked(reason: "終了します")
        lock.unlock()
    }

    /**
     * VM Service が立ち上がったことを伝える（設計 §2.2.5）。
     *
     * **同じ URI で何度呼ばれても一度しか送らない。** Hot Restart のたびに
     * Dart 側の `main()` が作り直され、同じ URI が再送されるため。
     */
    public func vmServiceReady(_ uri: String) {
        lock.lock()
        pendingVmServiceUri = uri
        let toSend: String?
        if sessionId == nil || uri == sentVmServiceUri {
            toSend = nil
        } else {
            sentVmServiceUri = uri
            toSend = uri
        }
        lock.unlock()

        guard let toSend = toSend else { return }
        os_log(
            "VM Service を伝えます: %{public}@",
            log: FluseRuntimeCore.log,
            type: .info,
            FluseRuntimeCore.maskAuthCode(toSend)
        )
        send(VmServiceReadyMessage(vmServiceUri: toSend))
    }

    // ------------------------------------------------------------ 送受信

    private func send(_ message: FluseMessage) {
        lock.lock()
        let current = socket
        lock.unlock()
        guard let current = current else { return }

        // Kotlin 側は `JSONObject.toString()` が失敗しない前提で組んでいる
        // （`toJson()` が積む値は文字列・数値・配列・オブジェクトだけ）。
        // Swift の `JSONSerialization` も同じ範囲の値なら失敗しないはずだが、
        // フォールバックで握り潰さず、失敗時は明示的にログを残す。
        guard
            let data = try? JSONSerialization.data(withJSONObject: message.toJson()),
            let text = String(data: data, encoding: .utf8)
        else {
            os_log(
                "送信するメッセージを JSON にできません: %{public}@",
                log: FluseRuntimeCore.log,
                type: .error,
                message.type
            )
            return
        }
        _ = current.sendText(text)
    }

    private func openSocket(forGeneration: Int) {
        lock.lock()
        let target: FluseEndpoint?
        if stopped || generation != forGeneration {
            target = nil
        } else {
            target = endpoint
        }
        lock.unlock()
        guard let target = target else { return }

        let events = Events(forGeneration: forGeneration, connection: self)
        let created = socketFactory.open(url: target.webSocketUrl(), events: events)

        lock.lock()
        if stopped || generation != forGeneration {
            lock.unlock()
            created.close(reason: "終了します")
            return
        }
        socket = created
        lock.unlock()

        // **繋がった通知は `socket` を入れる前に来ることがある。**
        // 先に来ていたら、ここで hello を送る。取りこぼすと名乗らないまま
        // 待ち続け、サーバから見れば無言の接続になる。
        events.attach()
    }

    /// 呼び出し元が `lock` を握っている前提。
    private func closeSocketLocked(reason: String) {
        socket?.close(reason: reason)
        socket = nil
        sessionId = nil
        sentVmServiceUri = nil
    }

    private func sendHello() {
        lock.lock()
        let pairing = pairingToken
        let hello = HelloMessage(
            protocolVersion: Int64(fluseProtocolVersion),
            projectId: appInfo.projectId,
            flutterRevision: appInfo.flutterRevision,
            dartVersion: appInfo.dartVersion,
            appVersion: appInfo.appVersion,
            deviceId: device.deviceId,
            deviceName: device.deviceName,
            // 片方だけ載せる。両方載せるとサーバが誤りとして断る。
            pairingToken: pairing,
            deviceToken: pairing == nil ? store.deviceToken : nil
        )
        lock.unlock()
        send(hello)
    }

    private func handleText(_ text: String) {
        let message: FluseMessage
        do {
            guard let data = text.data(using: .utf8) else {
                throw FluseProtocolException("制御メッセージを UTF-8 として読めません")
            }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw FluseProtocolException("制御メッセージが JSON オブジェクトではありません")
            }
            message = try FluseMessageDecoder.fromJson(object)
        } catch {
            // 読めないメッセージで接続ごと落とさない。次が読めるかもしれない。
            os_log(
                "制御メッセージを解釈できません: %{public}@",
                log: FluseRuntimeCore.log,
                type: .default,
                String(describing: error)
            )
            return
        }

        switch message {
        case let accept as AcceptMessage:
            handleAccept(accept)
        case let reject as RejectMessage:
            handleReject(reject)
        case let ping as PingMessage:
            // 受け取った値をそのまま返す。作り直すとサーバが RTT を測れない。
            send(ping.toPong())
        case let close as CloseMessage:
            handleClose(close)
        default:
            guard isAuthenticated else {
                os_log(
                    "受理前の制御メッセージを無視しました: %{public}@",
                    log: FluseRuntimeCore.log,
                    type: .default,
                    message.type
                )
                return
            }
            notifyListeners { $0.onMessage(message) }
        }
    }

    private func handleAccept(_ accept: AcceptMessage) {
        lock.lock()
        sessionId = accept.sessionId
        heartbeatIntervalMs = accept.heartbeatIntervalMs
        backoff.reset()

        // 発行されたら保存する。次回は QR を出さずに繋げる。
        if let issuedDeviceToken = accept.issuedDeviceToken {
            store.deviceToken = issuedDeviceToken
        }

        // 繋ぎ直した先は前のセッションを知らない。送り直す。
        sentVmServiceUri = nil
        let resend = pendingVmServiceUri
        lock.unlock()

        // 次に繋ぐときのために覚えておく。
        lock.lock()
        if let endpoint = endpoint {
            store.lastHost = endpoint.host
            store.lastPort = endpoint.port
        }
        // 使い切った。以後は deviceToken で繋ぐ。
        pairingToken = nil
        lock.unlock()

        os_log("接続しました: %{public}@", log: FluseRuntimeCore.log, type: .info, accept.sessionId)
        notifyListeners { $0.onConnected(sessionId: accept.sessionId) }
        if let resend = resend {
            vmServiceReady(resend)
        }
    }

    private func handleReject(_ reject: RejectMessage) {
        // **繋ぎ直しでは解けない。** どの理由も端末かサーバの構成違いで、
        // 待って再送しても同じ答えが返る（設計 §5.1）。
        lock.lock()
        stopped = true
        // 遅れて届く通知で再接続が動き出さないようにする。
        generation += 1
        closeSocketLocked(reason: "断られました")
        lock.unlock()
        os_log("接続を断られました: %{public}@", log: FluseRuntimeCore.log, type: .default, reject.code)

        if reject.knownCode == .authFailed {
            // 持っているトークンでは通らない。残すと次回も同じ所で止まる。
            store.deviceToken = nil
            notifyListeners { $0.onNeedsPairing(reason: reject.message) }
            return
        }
        notifyListeners { $0.onRejected(code: reject.code, message: reject.message) }
    }

    private func handleClose(_ close: CloseMessage) {
        os_log("サーバから切断されました: %{public}@", log: FluseRuntimeCore.log, type: .info, close.code)
        // **ソケットも閉じる。** 残すと URLSession 側の通知が後から来て、
        // 切断処理とバックオフが二重に走る。
        lock.lock()
        socket?.close(reason: "サーバが切断しました")
        let current = generation
        lock.unlock()
        // 正常終了でも繋ぎ直す。サーバが再起動しただけかもしれない。
        onDisconnected(forGeneration: current)
    }

    private func onDisconnected(forGeneration: Int) {
        lock.lock()
        // **古い接続の通知では何も消さない。** 閉じた直後の通知は新しい
        // ソケットが入った後に届くことがあり、そこで消すと生きている接続の
        // 状態が失われる。
        if generation != forGeneration {
            lock.unlock()
            return
        }
        socket = nil
        sessionId = nil
        sentVmServiceUri = nil
        let delayMs: Int? = stopped ? nil : backoff.next()
        lock.unlock()

        notifyListeners { $0.onDisconnected() }
        guard let delayMs = delayMs else { return }
        os_log("%{public}dms 後に繋ぎ直します", log: FluseRuntimeCore.log, type: .info, delayMs)
        scheduler.schedule(delayMs: delayMs) { [weak self] in
            self?.openSocket(forGeneration: forGeneration)
        }
    }

    /**
     * 1本のソケットから来る出来事。
     *
     * 開いた世代を持たせてある。後から届いた古い世代の通知は捨てる。
     *
     * Kotlin 版は `FluseConnection` の `inner class` として書かれており、
     * 暗黙に外側のインスタンスへアクセスできる。Swift のネスト型には
     * その仕組みが無いため、`connection` を明示的に持たせる。**強く持たない
     * （`weak`）。** ソケットのコールバックは `URLSession` 側が生かしている
     * `Adapter` 経由で届くため、`FluseConnection` → `socket` → `URLSession` →
     * `Adapter` → ここへ強参照が連なる形になっている。ここが `connection` を
     * 強く持ち返すと循環参照になる（Kotlin の GC は循環を回収できるが、
     * Swift の ARC は回収できないため、同じ書き方をすると単に解放されない
     * インスタンスが残るだけになる）。
     */
    private final class Events: FluseSocketEvents {
        private let forGeneration: Int
        private weak var connection: FluseConnection?
        private let gate = NSLock()
        private var opened = false
        private var attached = false

        init(forGeneration: Int, connection: FluseConnection) {
            self.forGeneration = forGeneration
            self.connection = connection
        }

        /// `openSocket` が `socket` を入れ終えたら呼ぶ。
        func attach() {
            gate.lock()
            attached = true
            let ready = opened
            gate.unlock()
            if ready {
                connection?.sendHello()
            }
        }

        func onOpen() {
            gate.lock()
            opened = true
            let ready = attached
            gate.unlock()
            if ready {
                connection?.sendHello()
            }
        }

        func onText(_ text: String) {
            if isStale() { return }
            connection?.handleText(text)
        }

        func onBinary(_ frame: Data) {
            // トンネルはこの PR の範囲外。受理前に binary が来ることは
            // 無いはずなので、黙って捨てずに気づける形で残す。
            os_log(
                "トンネルの受け手がまだありません（%d バイトを捨てました）",
                log: FluseRuntimeCore.log,
                type: .default,
                frame.count
            )
        }

        func onClosed(_ reason: String) {
            connection?.onDisconnected(forGeneration: forGeneration)
        }

        func onFailure(_ error: Error) {
            if isStale() { return }
            os_log(
                "接続が切れました: %{public}@",
                log: FluseRuntimeCore.log,
                type: .default,
                String(describing: error)
            )
            connection?.onDisconnected(forGeneration: forGeneration)
        }

        private func isStale() -> Bool {
            guard let connection = connection else { return true }
            connection.lock.lock()
            defer { connection.lock.unlock() }
            return connection.generation != forGeneration
        }
    }
}

// --------------------------------------------------------------- 差し込み口

/** 待ってから実行する。テストでは時間を進めずに動かす。 */
protocol RetryScheduler {
    func schedule(delayMs: Int, action: @escaping () -> Void)
}

/// 起動時に一度使うだけなので単一のキューで足りる。
///
/// Kotlin 版の `Executors.newSingleThreadScheduledExecutor`（デーモンスレッド
/// `"fluse-reconnect"`）に相当する。
private final class DispatchRetryScheduler: RetryScheduler {
    private let queue = DispatchQueue(label: "dev.fluse.runtime.reconnect")

    func schedule(delayMs: Int, action: @escaping () -> Void) {
        queue.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: action)
    }
}

/**
 * 端末側に残す設定への差し込み口（設計 §2.2.5 / §6.1）。
 *
 * **実ストレージ（Keychain 相当）はこの PR では実装しない。** Kotlin 版の
 * `FluseStore`（`EncryptedSharedPreferences` を使う本番実装込み）に相当する
 * ものは後続チケットで用意する。ここでは `FluseConnection` が必要とする
 * 最小限の読み書きだけをプロトコルとして切り出し、テストでは in-memory な
 * フェイクを差し込めるようにしてある。
 *
 * `lastPort` は Kotlin 版が「未設定」を表すのに `NO_PORT = -1` という番兵
 * 値を使っているが、Swift では `Int?` で素直に表現できるためそちらを使う
 * （ワイヤ表現にもステートマシンの判定にも関与しない、保存値の形だけの
 * 違い）。
 */
public protocol FluseConnectionStore: AnyObject {
    /// ペアリング済みなら値が入る。無ければ nil。
    var deviceToken: String? { get set }
    /// 前回繋がったサーバのホスト。
    var lastHost: String? { get set }
    /// 前回繋がったサーバのポート。未設定は nil。
    var lastPort: Int? { get set }
}

/**
 * この端末の名乗り（設計 §2.2.1 の `hello`）。
 *
 * 移植元: `packages/fluse_runtime/android/src/main/kotlin/dev/fluse/runtime/FluseAppInfo.kt`
 * （`FluseDeviceInfo` 部分、61-75行目）。
 *
 * **`of(context:store:)` は移植しない。** ANDROID_ID 相当の端末識別子の
 * 取得（`DeviceIdentity`）は iOS 側では `identifierForVendor` 等に
 * 置き換わり、実機・シミュレータでの挙動差もあるため、この PR の対象外
 * （後続チケット）。ここでは呼び出し側が組み立てた値をそのまま受け取る。
 */
public struct FluseDeviceInfo: Equatable {
    public let deviceId: String
    public let deviceName: String

    public init(deviceId: String, deviceName: String) {
        self.deviceId = deviceId
        self.deviceName = deviceName
    }
}

/// 接続の行方を受け取る側。表示と画面遷移が使う。
public protocol FluseConnectionListener: AnyObject {
    /// 受理された。
    func onConnected(sessionId: String)

    /**
     * 断られた。**再試行しない。**
     *
     * どの理由も繋ぎ直しでは解けない（設計 §5.1）。
     */
    func onRejected(code: String, message: String)

    /// ペアリングからやり直す必要がある。
    func onNeedsPairing(reason: String)

    /// 切れた。再接続は `FluseConnection` が自分で行う。
    func onDisconnected()

    /**
     * 端末の設定で `ws://` が塞がれている（設計 §10-4）。
     *
     * **この PR ではどこからも呼ばれない。** `FluseCleartext` 相当の事前
     * 判定を実装していないため（`FluseConnection.connect` のコメント参照）。
     * インターフェースの形だけ Kotlin と揃えてあり、既定では何もしない。
     */
    func onCleartextBlocked(host: String, message: String)

    /// 受理後に届いた制御メッセージ。`reload` などは後続タスクが使う。
    func onMessage(_ message: FluseMessage)
}

extension FluseConnectionListener {
    public func onCleartextBlocked(host: String, message: String) {}
}
