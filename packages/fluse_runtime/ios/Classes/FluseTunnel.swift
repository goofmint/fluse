import Foundation
import Network

/// 端末側のトンネル終端（設計 §2.2.3(e)）。
///
/// 移植元: `packages/fluse_runtime/android/src/wire/kotlin/dev/fluse/runtime/FluseTunnel.kt`
///
/// サーバ側 `TunnelEndpoint`（Dart, `packages/fluse_server/lib/src/tunnel_endpoint.dart`）の
/// **鏡像**。あちらは localhost に TCP を待ち受けて、来た接続を `open` として
/// 送り出す。こちらは `open` を受け取って端末の `127.0.0.1:<vmServicePort>` へ
/// **自分から接続する**。
///
/// Android の Dart VM Service は端末の `127.0.0.1` にしかバインドされず、
/// LAN から直接は届かない。WebSocket の中を生 TCP で運ぶことで越える。
///
/// **プロトコルは一切解釈しない**（設計 §10-3）。VM Service は JSON-RPC over
/// WebSocket と DevFS の HTTP PUT を同じポートで受けるため、片方だけ対応した
/// 「賢いプロキシ」は必ず破綻する。ここはバイト列を運ぶだけ。
///
/// バックプレッシャ（high/low watermark）とロガーは本クラスの範囲外。
/// 後から足せるよう、送信は `send`、破棄は `closeStream` に集約してある。
///
/// 本番の `FluseConnection` / `FluseSocket` への配線は**このタスクの範囲外**
/// （Kotlin 側も同様）。`TunnelChannel` 抽象越しにしておく。
///
/// ## 並行処理モデルについて（このファイルだけ Swift Concurrency）
///
/// 既存の `FluseSocket.swift` / `FluseConnection.swift` は `NSLock` +
/// delegate コールバックで書かれており、このリポジトリの標準はそちらである。
/// それでもここだけ `actor` / `Task` / `AsyncThrowingStream` を使うのは、
/// 移植元の Kotlin がまさに coroutine（`Flow` の `collect`、`Channel` による
/// per-stream の送信キュー、`Mutex` によるフレーム送信の直列化）を前提に
/// 書かれているため。per-stream の双方向コピーと（弱い）バックプレッシャを
/// `NSLock` ベースのコールバックの組み合わせで書き直すと、Kotlin の構造
/// （受信ループ / per-stream の reader・writer coroutine / チャネルが
/// 満杯なら送信元を待たせる）との対応が取りづらくなり、移植としての
/// 正しさを検証しにくくなる。VM Service への実接続には `Network.framework`
/// の `NWConnection` を使うが、そのコールバック API は
/// `withCheckedThrowingContinuation` で `async` に橋渡しし、それ以外は
/// Swift Concurrency の構造化された形（`actor` による排他、`Task` に
/// よる並行実行）に素直に対応させてある。
///
/// **デプロイターゲットは変更していない。** `Package.swift` は
/// `.iOS(.v13)` / `.macOS(.v11)` のまま、`fluse_runtime.podspec` も
/// `swift_version = '5.0'` のままで、`actor` / `async` /
/// `AsyncThrowingStream` には `@available(iOS 13.0, macOS 11.0, *)` を
/// 付けて使っている。Swift Concurrency のランタイムは Xcode 13.2 以降、
/// iOS 13 / macOS 10.15 まで back-deploy されているため、デプロイ
/// ターゲットの引き上げなしに利用できる。
@available(iOS 13.0, macOS 11.0, *)
public actor FluseTunnel {
    /// VM Service は端末のループバックにしか居ない。
    public static let loopbackHost = "127.0.0.1"

    /// 接続の待ち時間（ミリ秒）。
    ///
    /// 相手はループバックなので、繋がるか即座に拒否されるかのどちらか。
    /// それでも上限を置く。**無制限にすると受信ループが止まり、
    /// 他のストリームまで巻き添えになる。**
    public static let connectTimeoutMs = 5_000

    /// TCP から一度に読む量。
    ///
    /// `TunnelFrame.maxPayloadLength` 以下にしておくことで、読んだ塊が
    /// そのまま1フレームに収まる。プロトコル層は自動では割らず、超えたら
    /// 例外にする約束なので、ここで守る。
    public static let readBufferLength = 64 * 1024

    /// 1ストリームあたりの送信待ち行列の容量。
    ///
    /// これを超えると受信ループが待たされる。**捨てるよりは待たせる。**
    /// 落としたバイトは相手には届いたように見え、VM Service のストリームが
    /// 黙って壊れる。本来のバックプレッシャは後のタスク。
    public static let outboundCapacity = 64

    /// `NWConnection` のコールバックをまとめて処理する専用キュー。
    ///
    /// Kotlin 版が `Dispatchers.IO` にブロッキング呼び出しを逃がすのに
    /// 相当する。`Network.framework` はコールバックベースなのでブロッキング
    /// スレッドは不要だが、コールバックを1本のキューに集約しておくことで
    /// `NWConnection` 側の実行順序についての前提を単純に保てる。
    private static let ioQueue = DispatchQueue(label: "dev.fluse.runtime.tunnel")

    /// 端末上の VM Service のポート。
    ///
    /// **`UInt16` で持つ。** Kotlin は符号付き `Int` で持ち範囲外を実行時に
    /// 弾いているが（`vmServicePort in 1..65535`）、Swift では `UInt16` と
    /// いう型そのものが 0...65535 の範囲を保証するため、上限側の検査を
    /// 型に肩代わりさせられる（`TunnelFrame.streamId` を `UInt32` にした
    /// のと同じ考え方）。下限（0 はポートとして無効）だけは実行時に弾く。
    public nonisolated let vmServicePort: UInt16

    private let channel: TunnelChannel

    /// 中継中のストリーム。
    ///
    /// Kotlin 版は `streamsMutex` で守るが、`actor` の isolation がそのまま
    /// 同じ役割を果たすため、専用のロックは不要。
    private var streams: [UInt32: TunnelStream] = [:]

    /// フレームは丸ごと・順番どおりに送る。割り込まれると相手が復号できない。
    ///
    /// **`actor` の isolation だけでは足りない。** `send` は `await` を挟む
    /// （`channel.send` の完了を待つ）ため、`actor` はその間 isolation を
    /// 手放し、別の `send` 呼び出しが割り込める。Kotlin 版の `sendMutex`
    /// と同じ役割の `AsyncMutex` を別途持つ。
    private let sendMutex = AsyncMutex()

    private var closing = false

    /// `start()` の二重起動よけ。
    private var started = false

    /// 受信が失敗した理由。`close()` が待ち手をこれで終わらせる。
    private var terminationError: Error?

    private var receiveTask: Task<Void, Never>?

    /// `done` を待っている呼び出し元。
    ///
    /// Kotlin 版の `CompletableDeferred<Unit>` は複数回・複数箇所から
    /// `await()` できるが、Swift の `CheckedContinuation` は一度きりしか
    /// 再開できない。ここでは `close()` 前に呼ばれた `waitUntilDone()` の
    /// 継続を貯めておき、`close()` が一括で再開する。`close()` の後に
    /// 呼ばれた分は `terminationResult` を見て即座に返す。
    private var terminationWaiters: [CheckedContinuation<Void, Error>] = []
    private var terminationResult: Result<Void, Error>?

    public init(vmServicePort: UInt16, channel: TunnelChannel) throws {
        guard vmServicePort >= 1 else {
            // **ここで弾かないと open のたびに不正なポートで接続を試みる。**
            // Kotlin 版は `require` でコンストラクタ自体を失敗させている。
            // Swift の `actor` は throwing init を書けるため、同じ意図を
            // クラッシュではなく呼び出し元が catch できる形で表現する
            // （Kotlin の `require` は未捕捉なら実行時クラッシュになるが、
            // ここではテストからも安全に呼べるようにする）。
            throw TunnelException("vmServicePort が範囲外です: \(vmServicePort)")
        }
        // `READ_BUFFER_LENGTH <= TunnelFrame.maxPayloadLength` は両方とも
        // コンパイル時定数なので、ここで一度だけ検査すれば足りる。
        precondition(
            FluseTunnel.readBufferLength <= TunnelFrame.maxPayloadLength,
            "readBufferLength が1フレームの上限を超えています"
        )
        self.vmServicePort = vmServicePort
        self.channel = channel
    }

    /// 中継中のストリーム数。
    public var activeStreams: Int { streams.count }

    /// 受信ループを開始する。2度目以降は何もしない。
    public func start() {
        // `actor` の isolation により、同時に呼ばれても `started` の
        // 判定と代入の間に別の呼び出しが割り込むことはない
        // （Kotlin 版が `AtomicBoolean.compareAndSet` で守っている性質を
        // `actor` の性質でそのまま得られる）。
        guard !started else { return }
        started = true

        // `Task` の外へ出す前に `channel.incoming` を読む。`actor` の
        // 外（`Task` の本体）から `self.channel` へ触れると isolation を
        // 跨ぐ手間が増えるため、値そのものを先に取り出して渡す。
        let incoming = channel.incoming

        // **`self` は弱参照で持つ。** `receiveTask` を `self` の
        // プロパティに保存しつつ、そのクロージャが `self` を強参照すると
        // 循環参照になり、`FluseTunnel` が解放されなくなる
        // （`FluseConnection.swift` の `Events` が `connection` を
        // `weak` で持つのと同じ理由）。
        receiveTask = Task { [weak self] in
            var caughtError: Error?
            do {
                for try await bytes in incoming {
                    guard let self else { return }
                    await self.handleIncomingFrame(bytes)
                }
            } catch is CancellationError {
                // `close()` からの中断。エラーとしては扱わない。
            } catch {
                caughtError = error
            }
            guard let self else { return }
            if let caughtError {
                await self.setTerminationError(
                    TunnelException("トンネルの受信が失敗しました", cause: caughtError)
                )
            }
            // 正常終了・異常終了どちらでも中継は続けられない。
            await self.close()
        }
    }

    /// 全ストリームを閉じ、`waitUntilDone()` の待ち手を解放する。二重に
    /// 呼んでも安全。
    public func close() async {
        guard !closing else { return }
        closing = true

        let snapshot = Array(streams.values)
        streams.removeAll()
        for stream in snapshot {
            await stream.dispose()
        }

        // 受信ループがまだ生きていれば止める。
        //
        // Kotlin 版の「job.cancel() は最後に置く（早すぎると自分自身が
        // 途中で止まる）」という注意はここには当てはまらない。Swift の
        // `Task` のキャンセルは cooperative（協調的）で、`cancel()` を
        // 呼んでも実行中のコードが強制中断されるわけではないため、
        // 呼ぶ位置がここでも安全。それでも Kotlin 版と対応が付くように
        // 後始末の最後に置いてある。
        receiveTask?.cancel()

        resolveTerminationWaiters()
    }

    /// トンネルが終わるまで待つ。
    ///
    /// チャネルが閉じた・受信でエラーが出た場合もここで分かる。
    /// **呼び出し元はこれを監視すること。** 監視しないと、中継が
    /// 止まっていることに気づけない。
    ///
    /// Kotlin 版はプロパティ（`done: CompletableDeferred<Unit>`）だが、
    /// Swift 側では `actor` 越しの一回性の待ち合わせとして関数にしてある。
    public func waitUntilDone() async throws {
        if let terminationResult {
            try terminationResult.get()
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            terminationWaiters.append(continuation)
        }
    }

    private func setTerminationError(_ error: Error) {
        terminationError = error
    }

    private func resolveTerminationWaiters() {
        let waiters = terminationWaiters
        terminationWaiters.removeAll()
        if let error = terminationError {
            terminationResult = .failure(error)
            waiters.forEach { $0.resume(throwing: error) }
        } else {
            terminationResult = .success(())
            waiters.forEach { $0.resume(returning: ()) }
        }
    }

    // ------------------------------------------------------- WebSocket -> TCP

    private func handleIncomingFrame(_ bytes: [UInt8]) async {
        guard let frame = try? TunnelFrame.decode(bytes) else {
            // 壊れたフレームはどのストリームのものかも分からない。
            // ループは続ける。1 フレームの破損で中継全体を落とさない。
            return
        }

        switch frame.opcode {
        case .open:
            await openStream(streamId: frame.streamId)
        case .data:
            await writeToStream(frame)
        case .close:
            // 相手へ close を送り返さない。応酬が終わらなくなる。
            await closeStream(streamId: frame.streamId, notifyPeer: false)
        }
    }

    /// VM Service へ自分から繋ぐ。
    ///
    /// 接続はこの受信ループの中で待つ。別の `Task` に逃がすと、直後に
    /// 届いた同じ streamId の `data` が登録前に来て、開いたばかりの
    /// ストリームを「未知」として閉じてしまう。
    private func openStream(streamId: UInt32) async {
        if streams[streamId] != nil {
            // 相手の採番が壊れている。開き直すと既存の中継が黙って壊れる。
            await send(.close(streamId: streamId))
            return
        }

        let connection: NWConnection
        do {
            connection = try await Self.connectToVmService(port: vmServicePort)
        } catch {
            // VM Service がまだ立っていない / 落ちた。開けないことを伝える。
            await send(.close(streamId: streamId))
            return
        }

        if closing {
            // close と競合した。登録簿に残さないので、ここで畳む。
            connection.cancel()
            return
        }

        let stream = TunnelStream(
            streamId: streamId,
            connection: connection,
            outboundCapacity: FluseTunnel.outboundCapacity
        )
        streams[streamId] = stream

        stream.readerTask = Task { [weak self] in
            await self?.forwardToTunnel(stream: stream)
        }
        stream.writerTask = Task { [weak self] in
            await self?.drainOutbound(stream: stream)
        }
    }

    private func writeToStream(_ frame: TunnelFrame) async {
        guard let stream = streams[frame.streamId] else {
            // 既に閉じたストリーム宛。相手がまだ知らないだけなので伝える。
            await send(.close(streamId: frame.streamId))
            return
        }

        if await !stream.outbound.enqueue(frame.payload) {
            await closeStream(streamId: frame.streamId, notifyPeer: true)
        }
    }

    /// 受け取ったバイト列をソケットへ書く。ストリームごとに1本だけ走る。
    private func drainOutbound(stream: TunnelStream) async {
        while let payload = await stream.outbound.dequeue() {
            do {
                try await Self.sendOnConnection(stream.connection, payload: payload)
            } catch {
                await closeStream(streamId: stream.streamId, notifyPeer: true)
                return
            }
        }
        // `outbound` がクローズ済み・空で終わった（＝別経路で既に畳まれた）。
        // Kotlin 版の `for (payload in stream.outbound)` が正常終了する
        // ケースと同じで、ここでは何もしなくてよい。
    }

    // ------------------------------------------------------- TCP -> WebSocket

    /// ソケットから読んだバイト列をフレームに割って送る。
    ///
    /// 分割は中継側の責務。プロトコル層は自動では割らない。
    private func forwardToTunnel(stream: TunnelStream) async {
        while true {
            let chunk: [UInt8]?
            do {
                chunk = try await Self.receiveOnce(stream.connection)
            } catch {
                // 破棄で接続を閉じた場合もここに来る。`closeStream` は
                // 登録簿から消えていれば何もしないので、二重には送らない。
                break
            }
            guard let chunk else {
                // EOF。VM Service 側が閉じた。
                break
            }
            if chunk.isEmpty {
                continue
            }
            await send(.data(streamId: stream.streamId, payload: chunk))
        }

        await closeStream(streamId: stream.streamId, notifyPeer: true)
    }

    // ------------------------------------------------------------- ライフサイクル

    /// フレームを1つ送る。**送信はすべてここを通る。**
    ///
    /// 送れなかったフレームは失われる。相手は届いたと思って待ち続けるので、
    /// 該当ストリームを畳む。close フレームも同じチャネルを通るため、
    /// こちらからは送らない。
    ///
    /// **Kotlin 版と異なり、符号化に失敗しても例外を投げない。** Kotlin の
    /// `send` は `encode()` が失敗すると `TunnelException` を投げ、
    /// 呼び出し元によって伝播先が変わる（受信ループ直下からの呼び出しは
    /// `start()` の try/catch まで届きトンネル全体を畳むが、per-stream の
    /// reader/writer coroutine から呼ばれた場合は行き場がなく、実質
    /// 握りつぶされる）。ここでは呼び出し元に関わらず同じ挙動になるよう、
    /// 符号化失敗もチャネル送信失敗と同様に「そのストリームだけを閉じる」
    /// で統一する。open/close/data はすべて本ファイル内部で組み立てるため、
    /// 実運用でここに来ることは無いはずの経路であることは Kotlin 版と同じ。
    private func send(_ frame: TunnelFrame) async {
        guard let bytes = try? frame.encode() else {
            await closeStream(streamId: frame.streamId, notifyPeer: false)
            return
        }

        let channel = self.channel
        do {
            try await sendMutex.withLock {
                try await channel.send(bytes)
            }
        } catch {
            // Kotlin 版は `CancellationException` だけ再送出し、それ以外は
            // ストリームを畳んでいる。Swift 版は上のヘッダコメントの通り
            // `send` 自体を投げない設計にしたため、キャンセルも含めて一律
            // 「このストリームを畳む」で扱う（`closeStream` は `streams`
            // から既に消えていれば何もしないので、二重には壊れない）。
            await closeStream(streamId: frame.streamId, notifyPeer: false)
        }
    }

    private func closeStream(streamId: UInt32, notifyPeer: Bool) async {
        guard let stream = streams.removeValue(forKey: streamId) else { return }

        if notifyPeer, !closing {
            await send(.close(streamId: streamId))
        }
        await stream.dispose()
    }

    // ---------------------------------------------------------- NWConnection 橋渡し

    /// VM Service へ TCP で接続する。
    ///
    /// `NWConnection` はコールバックベースなので `withCheckedThrowingContinuation`
    /// で `async` に橋渡しする。Kotlin 版の `Socket().connect(...)` を
    /// `Dispatchers.IO` で待つのに相当する。
    private static func connectToVmService(port: UInt16) async throws -> NWConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw TunnelException("不正な vmServicePort です: \(port)")
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(loopbackHost),
            port: nwPort,
            using: .tcp
        )

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWConnection, Error>) in
            // 状態通知とタイムアウトが同時に発火しても、どちらか一方だけが
            // `continuation` を再開するようにする（`CheckedContinuation` は
            // 二重に再開されると即クラッシュする）。両方とも `ioQueue`
            // （直列キュー）上で呼ばれるので実際には競合しないが、
            // ネストした関数をコールバックから直接呼ぶと Swift の
            // Sendable 検査に引っかかるため、`NSLock` で守るクラスに
            // まとめる（`FluseSocket.swift` の `Adapter.detach()` と同じ
            // 形の "一度だけ" ガード）。
            let settle = ConnectSettlement(connection: connection, continuation: continuation)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    settle.succeed()
                case let .failed(error):
                    settle.fail(error)
                case .cancelled:
                    settle.fail(TunnelException("接続がキャンセルされました"))
                default:
                    break
                }
            }

            ioQueue.asyncAfter(deadline: .now() + .milliseconds(connectTimeoutMs)) {
                settle.fail(TunnelException("接続がタイムアウトしました（\(connectTimeoutMs)ms）"))
            }

            connection.start(queue: ioQueue)
        }
    }

    /// 接続から1回分だけ読む。EOF なら nil。
    private static func receiveOnce(_ connection: NWConnection) async throws -> [UInt8]? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8]?, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: readBufferLength) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: [UInt8](data))
                    return
                }
                if isComplete {
                    continuation.resume(returning: nil)
                    return
                }
                // データも無く・エラーも無く・完了もしていない通知は
                // `NWConnection` の仕様上ほぼ起きないはずだが、念のため
                // 空データとして返し、呼び出し元でループさせる（無視して
                // 何も再開しないと継続が永遠に解決されない）。
                continuation.resume(returning: [])
            }
        }
    }

    /// 接続へ1回分書く。
    private static func sendOnConnection(_ connection: NWConnection, payload: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: Data(payload),
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            )
        }
    }
}

/// `NWConnection.connectToVmService` の「状態通知 or タイムアウトの
/// どちらか早い方だけを採用する」を一度だけ実行させるためのガード。
///
/// `withCheckedThrowingContinuation` に渡すクロージャの中でネストした
/// 関数を複数のコールバック（`stateUpdateHandler` と `asyncAfter`）から
/// 呼ぶと、Swift の並行性検査が「並行に実行されうる」とみなして
/// `@Sendable` を要求してくる。実際には `FluseTunnel.ioQueue`（直列
/// キュー）上でしか呼ばれず競合しないが、検査を素直に通すために
/// `NSLock` で守るクラスへ切り出す。
/// **`@unchecked Sendable`**: 中身は `NSLock` で保護しており、複数の
/// キュー・クロージャから同時に触られても安全なことを手動で保証している。
@available(iOS 13.0, macOS 11.0, *)
private final class ConnectSettlement: @unchecked Sendable {
    private let connection: NWConnection
    private let continuation: CheckedContinuation<NWConnection, Error>
    private let lock = NSLock()
    private var settled = false

    init(connection: NWConnection, continuation: CheckedContinuation<NWConnection, Error>) {
        self.connection = connection
        self.continuation = continuation
    }

    func succeed() {
        guard markSettled() else { return }
        connection.stateUpdateHandler = nil
        continuation.resume(returning: connection)
    }

    func fail(_ error: Error) {
        guard markSettled() else { return }
        connection.stateUpdateHandler = nil
        // **失敗した接続も閉じる。** connect の途中でリソースが割り当たって
        // いることがある。VM Service がまだ立っていない間 open は繰り返し
        // 届くので、放置すると失敗のたびに溜まる（Kotlin 版が失敗した
        // `Socket` を必ず閉じるのと同じ理由）。
        connection.cancel()
        continuation.resume(throwing: error)
    }

    private func markSettled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if settled { return false }
        settled = true
        return true
    }
}

// ------------------------------------------------------------------ 補助型

/// 中継中の1ストリーム。
///
/// Kotlin 版の `private class TunnelStream`（`FluseTunnel.kt` 内）に相当。
/// `readerTask` / `writerTask` の代入と `dispose()` の呼び出しはすべて
/// `FluseTunnel`（actor）の isolation 下でしか行われないため、この型自体は
/// 追加のロックを持たない。
@available(iOS 13.0, macOS 11.0, *)
private final class TunnelStream {
    let streamId: UInt32
    let connection: NWConnection

    /// WebSocket から届いたバイト列の行き先。
    ///
    /// 受信ループから直接書き込むと、詰まった1本が全ストリームを止める。
    /// ソケットごとに1本の書き手（`writerTask`）を立てて順序も守る。
    let outbound: TunnelOutboundQueue

    var readerTask: Task<Void, Never>?
    var writerTask: Task<Void, Never>?

    private var disposed = false

    init(streamId: UInt32, connection: NWConnection, outboundCapacity: Int) {
        self.streamId = streamId
        self.connection = connection
        self.outbound = TunnelOutboundQueue(capacity: outboundCapacity)
    }

    /// 破棄する。二重に呼んでも安全。
    ///
    /// **接続を先に閉じる。** Kotlin 版は「ブロッキングの read / write に
    /// 入った coroutine は cancel では起きない。閉じて例外を起こして
    /// 初めて抜ける」という理由で socket を先に閉じているが、
    /// `NWConnection` はブロッキングではなくコールバックベースなので
    /// この理由はそのままには当てはまらない。それでも `cancel()` を先に
    /// 呼んでおくことで、進行中の `receive` / `send` のコールバックに
    /// 速やかにエラーが返るようにし、`readerTask` / `writerTask` の
    /// `cancel()` と合わせて二重に後始末する。
    func dispose() async {
        guard !disposed else { return }
        disposed = true

        await outbound.close()

        connection.stateUpdateHandler = nil
        connection.cancel()

        // join しない。自分自身の Task から呼ばれることがある
        // （`forwardToTunnel` / `drainOutbound` の末尾から `closeStream`
        // 経由でここに来る）。
        readerTask?.cancel()
        writerTask?.cancel()
    }
}

/// ストリームごとの送信待ち行列。
///
/// Kotlin 版の `kotlinx.coroutines.channels.Channel<ByteArray>(capacity = 64)`
/// に相当する。`AsyncStream` は容量超過時に古い/新しい要素を「捨てる」
/// バッファリングしかできず、Kotlin の「容量を超えたら送信元を待たせる」
/// という back-pressure を再現できないため、`actor` で自作する。
///
/// **`private` ではなく（デフォルトの）internal にしてある。** テスト
/// （`FluseTunnelTests.swift`）がこの back-pressure / FIFO を単体で
/// 直接確かめるための可視性で、`@testable import` はモジュール内
/// `internal` までしか届かず file-private な `private` は越えられない。
/// 挙動そのものは変えていない。
@available(iOS 13.0, macOS 11.0, *)
actor TunnelOutboundQueue {
    private var buffer: [[UInt8]] = []
    private var closed = false
    private let capacity: Int

    private var sendWaiters: [CheckedContinuation<Void, Never>] = []
    private var receiveWaiters: [CheckedContinuation<Void, Never>] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    /// 積む。積めなければ false（クローズ済み）。
    ///
    /// **満杯なら空きが出るまで待つ。** Kotlin 版の `outbound.send(payload)`
    /// が満杯で suspend するのと同じ。ここが待つことで、これを呼んでいる
    /// `FluseTunnel` の受信ループ側も連動して足止めされる
    /// （`writeToStream` → `enqueue` の呼び出し元が受信ループそのもの）。
    func enqueue(_ payload: [UInt8]) async -> Bool {
        while !closed, buffer.count >= capacity {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                sendWaiters.append(continuation)
            }
        }
        guard !closed else { return false }
        buffer.append(payload)
        wakeOneReceiver()
        return true
    }

    /// 取り出す。クローズ済みかつ空なら nil。
    func dequeue() async -> [UInt8]? {
        while buffer.isEmpty, !closed {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                receiveWaiters.append(continuation)
            }
        }
        guard !buffer.isEmpty else { return nil }
        let value = buffer.removeFirst()
        wakeOneSender()
        return value
    }

    /// クローズする。待っている送り手・受け手を両方起こす。
    func close() {
        guard !closed else { return }
        closed = true
        wakeAllSenders()
        wakeAllReceivers()
    }

    private func wakeOneReceiver() {
        guard !receiveWaiters.isEmpty else { return }
        let waiter = receiveWaiters.removeFirst()
        waiter.resume(returning: ())
    }

    private func wakeOneSender() {
        guard !sendWaiters.isEmpty else { return }
        let waiter = sendWaiters.removeFirst()
        waiter.resume(returning: ())
    }

    private func wakeAllSenders() {
        let waiters = sendWaiters
        sendWaiters.removeAll()
        waiters.forEach { $0.resume(returning: ()) }
    }

    private func wakeAllReceivers() {
        let waiters = receiveWaiters
        receiveWaiters.removeAll()
        waiters.forEach { $0.resume(returning: ()) }
    }
}

/// `channel.send` の呼び出しを直列化するだけの非同期ロック。
///
/// Kotlin 版の `kotlinx.coroutines.sync.Mutex` に相当する。`actor` の
/// isolation は「同時に1つの isolated メソッドしか *実行しない*」ことは
/// 保証するが、`await` で isolation を手放している間は別の呼び出しが
/// 割り込める。`FluseTunnel.send` は `channel.send` の完了を `await` する
/// ため、`actor` の isolation だけでは「1本ずつ完了を待ってから次を送る」
/// という直列化を再現できない。`locked` という明示的な状態で待ち行列を
/// 作ることで、`body` の実行中に他の呼び出しが割り込まないようにする。
@available(iOS 13.0, macOS 11.0, *)
private actor AsyncMutex {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        guard locked else {
            locked = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    private func release() {
        guard waiters.isEmpty else {
            let next = waiters.removeFirst()
            next.resume(returning: ())
            return
        }
        locked = false
    }
}
