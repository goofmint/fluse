import Foundation
import os.log

/// WebSocket の出来事を受け取る側。
///
/// `URLSession` のコールバックをそのまま外へ出さないための一枚。テストでは
/// 実ソケットを立てずにここへ流し込める。
///
/// 移植元: `packages/fluse_runtime/android/src/main/kotlin/dev/fluse/runtime/FluseSocket.kt`
protocol FluseSocketEvents: AnyObject {
    func onOpen()

    /// 制御メッセージ（設計 §2.2.1 の text frame）。
    func onText(_ text: String)

    /// トンネル（binary frame）。
    func onBinary(_ frame: Data)

    /// 閉じた。理由は表示とログのためだけに使う。
    func onClosed(_ reason: String)

    func onFailure(_ error: Error)
}

/// 張った WebSocket。
protocol FluseSocket: AnyObject {
    /// 制御メッセージを送る。閉じていれば false。
    @discardableResult
    func sendText(_ text: String) -> Bool

    /// トンネル（binary frame）を送る。
    ///
    /// **Kotlin 版には無い。** `OkHttpFluseSocketFactory` は制御メッセージ
    /// しか送らないため `sendText` だけで足りているが、`onBinary` の受け口が
    /// ある以上、送り口も対称に用意しておく（トンネル実装は Issue #91 の
    /// 後続。ここでは差し込み口だけ作る）。
    @discardableResult
    func sendBinary(_ frame: Data) -> Bool

    /// 閉じる。以後 `FluseSocketEvents` は呼ばれない。
    func close(reason: String)
}

/// URL と受け手からソケットを作る。テストで差し替える。
protocol FluseSocketFactory {
    func open(url: String, events: FluseSocketEvents) -> FluseSocket
}

/**
 * `URLSessionWebSocketTask` で張る実装。
 *
 * Kotlin 版の `OkHttpFluseSocketFactory` に相当する。OkHttp は1つの
 * `OkHttpClient` から複数の `WebSocket` を作れるが、`URLSession` は
 * デリゲートをセッション単位で持つため、ここでは **`open` を呼ぶたびに
 * 専用の `URLSession` を1本作る**。`FluseConnection` は同時に1本しか
 * ソケットを持たないため、セッションを使い回す複雑さを持ち込むより、
 * 1接続1セッションの単純な形の方が事故が少ない。
 */
final class URLSessionFluseSocketFactory: FluseSocketFactory {
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = URLSessionFluseSocketFactory.defaultConfiguration()) {
        self.configuration = configuration
    }

    /// 既定の設定。
    ///
    /// **WebSocket レベルの ping は使わない。** 生存確認は制御メッセージの
    /// `ping`/`pong`（設計 §2.2.1）でサーバが握っており、ここでも自動 ping を
    /// 打つと二重になる（Kotlin 版の `pingInterval(0, ...)` と同じ意図）。
    /// `URLSessionWebSocketTask` は明示的に `sendPing` を呼ばない限り自分から
    /// ping を送らないため、既定の設定のままで足りる。
    static func defaultConfiguration() -> URLSessionConfiguration {
        .default
    }

    func open(url: String, events: FluseSocketEvents) -> FluseSocket {
        guard let requestUrl = URL(string: url) else {
            // Kotlin 版は `Request.Builder().url(url)` が不正な URL で例外を
            // 投げるだけで、呼び出し元（`FluseConnection.openSocket`）も
            // catch していない。Swift では `URL(string:)` が例外ではなく nil を
            // 返す形で失敗するため、ここで黙って握りつぶさず、明示的な
            // `onFailure` として伝える（`FluseEndpoint.webSocketUrl()` が
            // 組み立てる形式である限り実際には起きないはずの経路）。
            events.onFailure(FluseProtocolException("不正な WebSocket URL: \(url)"))
            return NoopSocket()
        }

        let adapter = Adapter(events: events)
        let session = URLSession(configuration: configuration, delegate: adapter, delegateQueue: nil)
        let task = session.webSocketTask(with: requestUrl)
        let handle = Handle(session: session, task: task, adapter: adapter)
        adapter.startReceiving(from: task)
        task.resume()
        return handle
    }

    /// 何もしないハンドル。不正な URL のときだけ使う。
    private final class NoopSocket: FluseSocket {
        func sendText(_ text: String) -> Bool { false }
        func sendBinary(_ frame: Data) -> Bool { false }
        func close(reason: String) {}
    }

    /// `URLSessionWebSocketDelegate` / `URLSessionTaskDelegate` のコールバックを
    /// `FluseSocketEvents` に写す。
    private final class Adapter: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate {
        private let events: FluseSocketEvents

        /**
         * 切断を伝えるのは一度だけ。
         *
         * **判定と代入を分けてはいけない。** `close()` と `URLSession` の
         * コールバックは別のキューから同時に来る。読んでから書くまでの間に
         * 割り込まれると、閉じた後の `didCompleteWithError` が切断として
         * 通り、止めたはずの再接続がもう一度動き出す。Kotlin 版の
         * `AtomicBoolean` 相当を `NSLock` + `Bool` で実装する。
         */
        private let detachLock = NSLock()
        private var detachedFlag = false

        init(events: FluseSocketEvents) {
            self.events = events
        }

        /// まだ伝えていなければ true を返し、以後は false。
        @discardableResult
        func detach() -> Bool {
            detachLock.lock()
            defer { detachLock.unlock() }
            if detachedFlag { return false }
            detachedFlag = true
            return true
        }

        var detached: Bool {
            detachLock.lock()
            defer { detachLock.unlock() }
            return detachedFlag
        }

        /**
         * 受信ループを開始する（以後は自分で再帰する）。
         *
         * **`receive` は1本だけに保つ。** `URLSessionWebSocketTask` は
         * 同時に複数の `receive` 呼び出しを行うことを想定していない。1回の
         * 受信が完了してから次を呼ぶことで、常に1本の受信だけが飛んでいる
         * 状態を保つ（OkHttp は内部でメッセージを直列にコールバックするため
         * Kotlin 側にこの気配りは無い）。
         */
        func startReceiving(from task: URLSessionWebSocketTask) {
            if detached { return }
            task.receive { [weak self] result in
                guard let self = self else { return }
                if self.detached { return }
                switch result {
                case let .success(message):
                    switch message {
                    case let .string(text):
                        self.events.onText(text)
                    case let .data(data):
                        self.events.onBinary(data)
                    @unknown default:
                        break
                    }
                    // 続けて次を待つ。ここで再帰しないと1通しか受け取れない。
                    self.startReceiving(from: task)
                case let .failure(error):
                    // detach 済みなら握り潰す。正常に閉じた直後にも `receive` が
                    // 失敗として返ってくることがある。
                    guard self.detach() else { return }
                    self.events.onFailure(error)
                }
            }
        }

        func urlSession(
            _ session: URLSession,
            webSocketTask: URLSessionWebSocketTask,
            didOpenWithProtocol protocol: String?
        ) {
            if detached { return }
            events.onOpen()
        }

        func urlSession(
            _ session: URLSession,
            webSocketTask: URLSessionWebSocketTask,
            didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
            reason: Data?
        ) {
            guard detach() else { return }
            // `reason` は表示とログのためだけに使う値。`String(data:encoding:)`
            // は不正なバイト列で nil を返しうる（Kotlin の OkHttp は既に
            // デコード済みの `String` を渡してくるため、この分岐は無い）。
            // 用途が表示だけなので、デコードできなければ空文字に倒す
            // （接続状態の判断には使わない値であり、値の欠落が誤動作には
            // つながらない）。
            let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            events.onClosed(reasonText)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error = error else {
                // 正常終了。`didCloseWith` が既に `onClosed` を伝えているはず
                // なので、ここでは何もしない（detach 済みなら二重配送されない）。
                return
            }
            guard detach() else { return }
            // **`URLError` をそのまま渡す。** ATS（App Transport Security）で
            // `ws://` が拒まれた場合など、上位層が受動的に判定できるよう
            // 元の型のまま残す（設計 §10-4 相当の判定は本 PR の対象外）。
            events.onFailure(error)
        }
    }

    /// 張った WebSocket のハンドル。
    private final class Handle: FluseSocket {
        private let session: URLSession
        private let task: URLSessionWebSocketTask
        private let adapter: Adapter

        init(session: URLSession, task: URLSessionWebSocketTask, adapter: Adapter) {
            self.session = session
            self.task = task
            self.adapter = adapter
        }

        /// Kotlin の `WebSocket.send` は成否を同期的に返すが、
        /// `URLSessionWebSocketTask.send` は completion handler で非同期に
        /// 返す。ここでは「閉じていれば false」という Kotlin と同じ判定だけを
        /// 同期的に保つ。
        ///
        /// **completion handler のエラーでは `onFailure` を呼ばない。**
        /// Kotlin 側も `WebSocket.send` の戻り値を見ていない
        /// （`FluseConnection.send` は Bool を捨てている）ので、送信の成否を
        /// 特別扱いする理由がない。送信が失敗するような状況では
        /// `URLSessionTaskDelegate.didCompleteWithError` が別途タスクの終了を
        /// 伝えてくるはずで、終端イベントはそちら1本に絞る（ここでも
        /// `detach()` してしまうと、後から来る本物の `didCompleteWithError` が
        /// 握り潰されて `onFailure` が一度も届かなくなる恐れがある）。
        @discardableResult
        func sendText(_ text: String) -> Bool {
            if adapter.detached { return false }
            task.send(.string(text)) { error in
                guard let error = error else { return }
                os_log(
                    "送信に失敗しました: %{public}@",
                    log: FluseRuntimeCore.log,
                    type: .default,
                    String(describing: error)
                )
            }
            return true
        }

        @discardableResult
        func sendBinary(_ frame: Data) -> Bool {
            if adapter.detached { return false }
            task.send(.data(frame)) { error in
                guard let error = error else { return }
                os_log(
                    "送信に失敗しました: %{public}@",
                    log: FluseRuntimeCore.log,
                    type: .default,
                    String(describing: error)
                )
            }
            return true
        }

        func close(reason: String) {
            adapter.detach()
            // 1000 は正常終了。異常は WebSocket の close フレームに委ねる
            // （設計 §2.2.1 の CloseMessage の注記）。
            task.cancel(with: .normalClosure, reason: reason.data(using: .utf8))
            session.finishTasksAndInvalidate()
        }
    }
}
