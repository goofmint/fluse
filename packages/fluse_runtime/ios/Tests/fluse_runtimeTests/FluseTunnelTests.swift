import Network
import XCTest

@testable import fluse_runtime

/**
 * `FluseTunnel`（TCP ↔ WebSocket の中継、`FluseTunnel.swift`）を確かめる。
 *
 * 移植元: `packages/fluse_protocol_kt/src/test/kotlin/dev/fluse/runtime/FluseTunnelTest.kt`
 * （10ケース）。**TCP 側は実ソケットを使う。** Kotlin 版・サーバ側の
 * `tunnel_endpoint_test.dart` と同じ方針で、フェイクにするのは WebSocket
 * チャネル（`TunnelChannel`）だけにする。ブロッキング/非同期 I/O の畳み方
 * こそがこのクラスの難所なので、そこを偽物に置き換えるとテストの意味が
 * 無くなる。TCP 側は `LocalWebSocketTestServer.swift` と同じ
 * `Network.framework`（`NWListener`/`NWConnection`）で組む。
 *
 * Kotlin 版に無いケース（重複 streamId の open、`start()`/`close()` の
 * 冪等性、`TunnelOutboundQueue` の back-pressure/FIFO 単体確認、
 * `waitUntilDone()` がチャネルのエラーで失敗すること、`vmServicePort`
 * の範囲外検査）も併せて足してある。個々の理由は各テストのコメントを
 * 見ること。
 */
@available(iOS 13.0, macOS 11.0, *)
final class FluseTunnelTests: XCTestCase {
    // -------------------------------------------------------------- open

    func testOpenConnectsToVmService() async throws {
        let echo = try TcpEchoServer()
        defer { echo.stop() }
        let channel = FakeTunnelChannel()

        try await withTunnel(port: echo.port, channel: channel) { tunnel in
            channel.inject(.open(streamId: 1))

            // 接続できたことは、往復が成立することで確かめる。
            let sent = payload(length: 8)
            channel.inject(.data(streamId: 1, payload: sent))
            let received = try channel.collectData(streamId: 1, expectedLength: 8)
            XCTAssertEqual(sent, received)

            let active = await tunnel.activeStreams
            XCTAssertEqual(1, active)
            XCTAssertEqual(1, echo.connectionCount)
        }
    }

    // -------------------------------------------------------------- data

    func testDataRoundTrips() async throws {
        let echo = try TcpEchoServer()
        defer { echo.stop() }
        let channel = FakeTunnelChannel()

        try await withTunnel(port: echo.port, channel: channel) { _ in
            channel.inject(.open(streamId: 7))

            let sent = payload(length: 3000)
            channel.inject(.data(streamId: 7, payload: sent))

            let received = try channel.collectData(streamId: 7, expectedLength: sent.count)
            XCTAssertEqual(sent, received)
        }
    }

    func testLargeTransferIsSplitAndReassembledIntact() async throws {
        let echo = try TcpEchoServer()
        defer { echo.stop() }
        let channel = FakeTunnelChannel()

        try await withTunnel(port: echo.port, channel: channel, timeout: 60) { _ in
            channel.inject(.open(streamId: 1))

            // 1フレームの上限を明確に超える量を、上限以下ずつ流し込む。
            let total = 3 * TunnelFrame.maxPayloadLength + 12345
            let sent = payload(length: total)
            var offset = 0
            while offset < total {
                let end = min(offset + TunnelFrame.maxPayloadLength, total)
                channel.inject(.data(streamId: 1, payload: Array(sent[offset..<end])))
                offset = end
            }

            let received = try channel.collectData(streamId: 1, expectedLength: total, timeout: 30)
            XCTAssertEqual(sent, received)
        }
    }

    func testMultipleStreamsRoundTripIndependently() async throws {
        let echo = try TcpEchoServer()
        defer { echo.stop() }
        let channel = FakeTunnelChannel()

        try await withTunnel(port: echo.port, channel: channel) { tunnel in
            let ids: [UInt32] = [1, 2, 3]
            for id in ids {
                channel.inject(.open(streamId: id))
            }
            // ストリームごとに違う内容を流し、取り違えを検出する。
            var payloads: [UInt32: [UInt8]] = [:]
            for id in ids {
                payloads[id] = payload(length: 1000 + Int(id))
            }
            for id in ids {
                channel.inject(.data(streamId: id, payload: payloads[id]!))
            }

            for id in ids {
                let received = try channel.collectData(streamId: id, expectedLength: payloads[id]!.count)
                XCTAssertEqual(payloads[id]!, received, "streamId=\(id)")
            }
            let active = await tunnel.activeStreams
            XCTAssertEqual(3, active)
        }
    }

    // ------------------------------------------------------------- close

    func testCloseReceivedClosesSocketWithoutRespondingClose() async throws {
        let echo = try TcpEchoServer()
        defer { echo.stop() }
        let channel = FakeTunnelChannel()

        try await withTunnel(port: echo.port, channel: channel) { tunnel in
            channel.inject(.open(streamId: 1))
            channel.inject(.data(streamId: 1, payload: payload(length: 4)))
            _ = try channel.collectData(streamId: 1, expectedLength: 4)

            channel.inject(.close(streamId: 1))

            // 登録簿から消えるまで待つ。
            let closed = await waitUntil { await tunnel.activeStreams == 0 }
            XCTAssertTrue(closed, "ストリームが登録簿から消えませんでした")

            // **close は送り返さない。** 応酬が終わらなくなる。
            XCTAssertNil(channel.poll())
        }
    }

    func testDataToUnknownStreamIdReturnsClose() async throws {
        let echo = try TcpEchoServer()
        defer { echo.stop() }
        let channel = FakeTunnelChannel()

        try await withTunnel(port: echo.port, channel: channel) { _ in
            channel.inject(.data(streamId: 99, payload: payload(length: 4)))

            guard let frame = channel.next(timeout: 5) else {
                return XCTFail("close が返りませんでした")
            }
            XCTAssertEqual(.close, frame.opcode)
            XCTAssertEqual(99, frame.streamId)
        }
    }

    /// Kotlin 版の10ケースには無い。**実装（`openStream`）に既にある
    /// 分岐**（`streams[streamId] != nil` なら close を返して既存を
    /// 保つ）を確かめる。相手の採番が壊れているケースで、開き直すと
    /// 既存の中継が黙って壊れる。
    func testDuplicateStreamIdOpenReturnsCloseAndKeepsExistingStream() async throws {
        let echo = try TcpEchoServer()
        defer { echo.stop() }
        let channel = FakeTunnelChannel()

        try await withTunnel(port: echo.port, channel: channel) { tunnel in
            channel.inject(.open(streamId: 1))
            channel.inject(.data(streamId: 1, payload: payload(length: 4)))
            _ = try channel.collectData(streamId: 1, expectedLength: 4)

            // 同じ streamId で再度 open。
            channel.inject(.open(streamId: 1))

            guard let frame = channel.next(timeout: 5) else {
                return XCTFail("close が返りませんでした")
            }
            XCTAssertEqual(.close, frame.opcode)
            XCTAssertEqual(1, frame.streamId)

            // 既存のストリームは壊れていないことを、往復の継続で確かめる。
            let more = payload(length: 6)
            channel.inject(.data(streamId: 1, payload: more))
            let received = try channel.collectData(streamId: 1, expectedLength: 6)
            XCTAssertEqual(more, received)

            let active = await tunnel.activeStreams
            XCTAssertEqual(1, active, "既存ストリームが登録簿から消えています")
        }
    }

    // ------------------------------------------------------------ 接続失敗

    func testConnectFailureReturnsClose() async throws {
        let deadPort = try findRefusedPort()
        let channel = FakeTunnelChannel()

        try await withTunnel(port: deadPort, channel: channel) { tunnel in
            channel.inject(.open(streamId: 5))

            guard let frame = channel.next(timeout: 10) else {
                return XCTFail("close が返りませんでした")
            }
            XCTAssertEqual(.close, frame.opcode)
            XCTAssertEqual(5, frame.streamId)
            // 開けなかったストリームを登録簿に残さない。
            let active = await tunnel.activeStreams
            XCTAssertEqual(0, active)
        }
    }

    // -------------------------------------------------------- TCP 側の切断

    func testTcpDisconnectSendsClose() async throws {
        let echo = try TcpEchoServer()
        let channel = FakeTunnelChannel()

        try await withTunnel(port: echo.port, channel: channel) { tunnel in
            channel.inject(.open(streamId: 1))
            channel.inject(.data(streamId: 1, payload: payload(length: 4)))
            _ = try channel.collectData(streamId: 1, expectedLength: 4)

            // VM Service 側が落ちた状況を作る。
            echo.stop()

            var frame = channel.next(timeout: 10)
            while let current = frame, current.opcode != .close {
                frame = channel.next(timeout: 10)
            }
            guard let closeFrame = frame else {
                return XCTFail("close が返りませんでした")
            }
            XCTAssertEqual(1, closeFrame.streamId)
            let active = await tunnel.activeStreams
            XCTAssertEqual(0, active)
        }
    }

    // -------------------------------------------------------- チャネルの終了

    func testChannelClosedReleasesAllStreamsAndCompletesDone() async throws {
        let echo = try TcpEchoServer()
        defer { echo.stop() }
        let channel = FakeTunnelChannel()

        try await withTunnel(port: echo.port, channel: channel) { tunnel in
            channel.inject(.open(streamId: 1))
            channel.inject(.data(streamId: 1, payload: payload(length: 4)))
            _ = try channel.collectData(streamId: 1, expectedLength: 4)

            channel.closeIncoming()

            try await tunnel.waitUntilDone()
            let active = await tunnel.activeStreams
            XCTAssertEqual(0, active)
            XCTAssertTrue(echo.awaitAllClosed(timeout: 10), "VM Service 側の TCP が閉じられていません")
        }
    }

    /// Kotlin 版には無い。「チャネルが閉じた」だけでなく「チャネルの受信が
    /// **エラーで**終わった」場合も `waitUntilDone()` がそのエラーで
    /// 失敗することを確かめる。`FluseTunnel.start()` は捕まえたエラーを
    /// `TunnelException` でラップし直すので、そこまで見る。
    func testIncomingErrorFailsWaitUntilDoneAndCollapsesAllStreams() async throws {
        let echo = try TcpEchoServer()
        defer { echo.stop() }
        let channel = FakeTunnelChannel()
        let tunnel = try FluseTunnel(vmServicePort: echo.port, channel: channel)
        await tunnel.start()

        channel.inject(.open(streamId: 1))
        channel.inject(.data(streamId: 1, payload: payload(length: 4)))
        _ = try channel.collectData(streamId: 1, expectedLength: 4)

        channel.failIncoming(TunnelTestError(message: "テスト用の受信エラー"))

        do {
            try await tunnel.waitUntilDone()
            XCTFail("waitUntilDone がエラーで終わりませんでした")
        } catch {
            XCTAssertTrue(error is TunnelException, "TunnelException でラップされていません: \(error)")
        }

        let active = await tunnel.activeStreams
        XCTAssertEqual(0, active, "エラー終了時に全ストリームが畳まれていません")
        await tunnel.close()
    }

    // ------------------------------------------------------------- 送信失敗

    func testSendFailureCollapsesStream() async throws {
        let echo = try TcpEchoServer()
        defer { echo.stop() }
        let channel = FakeTunnelChannel()

        try await withTunnel(port: echo.port, channel: channel) { tunnel in
            channel.inject(.open(streamId: 1))
            channel.inject(.data(streamId: 1, payload: payload(length: 4)))
            _ = try channel.collectData(streamId: 1, expectedLength: 4)

            channel.failSend = true
            // エコーが返ってくると送信が失敗し、そのストリームが畳まれる。
            channel.inject(.data(streamId: 1, payload: payload(length: 4)))

            let closed = await waitUntil { await tunnel.activeStreams == 0 }
            XCTAssertTrue(closed)

            // **失敗するのは data の送信1回だけ。** close は送ろうとしない。
            // 回数を見ないと、notifyPeer の扱いを変えてもこのテストは通る。
            XCTAssertEqual(1, channel.failedSendCount)

            channel.failSend = false
            XCTAssertNil(channel.poll())
        }
    }

    // ------------------------------------------------------- 冪等性・多重起動

    /// Kotlin 版には無い。`close()` を複数回呼んでも安全（ドキュメント
    /// コメントが明言している契約）ことを確かめる。
    func testCloseIsIdempotent() async throws {
        let echo = try TcpEchoServer()
        defer { echo.stop() }
        let channel = FakeTunnelChannel()
        let tunnel = try FluseTunnel(vmServicePort: echo.port, channel: channel)
        await tunnel.start()

        channel.inject(.open(streamId: 1))
        channel.inject(.data(streamId: 1, payload: payload(length: 4)))
        _ = try channel.collectData(streamId: 1, expectedLength: 4)

        await tunnel.close()
        await tunnel.close()
        await tunnel.close()

        let active = await tunnel.activeStreams
        XCTAssertEqual(0, active)
        // 二重に呼んでも waitUntilDone は同じ結果を返す（正常終了）。
        try await tunnel.waitUntilDone()
    }

    /// Kotlin 版には無い。`start()` の二重起動よけ（`started` フラグ）を
    /// 確かめる。**受信ループが2本立つと `AsyncThrowingStream` の要素を
    /// 2本のループが奪い合い**、多チャンクの再結合が欠落・順序崩れで
    /// 壊れるはずなので、それが起きないことで間接的に検証する
    /// （ループの本数を直接数える手段が無いため）。
    func testStartIsIdempotentAndKeepsSingleReceiveLoop() async throws {
        let echo = try TcpEchoServer()
        defer { echo.stop() }
        let channel = FakeTunnelChannel()

        try await withTunnel(port: echo.port, channel: channel) { tunnel in
            // 2回目以降は無視されるはず。
            await tunnel.start()
            await tunnel.start()

            channel.inject(.open(streamId: 1))
            let sent = payload(length: 5000)
            channel.inject(.data(streamId: 1, payload: sent))

            let received = try channel.collectData(streamId: 1, expectedLength: sent.count)
            XCTAssertEqual(sent, received)

            let active = await tunnel.activeStreams
            XCTAssertEqual(1, active)
        }
    }

    // --------------------------------------------------------------- init

    /// Kotlin 版には無い（Kotlin は `require` で実行時クラッシュにしている）。
    /// Swift 版は throwing init にしてあるので、その契約を確かめる。
    func testInitRejectsZeroPort() {
        let channel = FakeTunnelChannel()
        XCTAssertThrowsError(try FluseTunnel(vmServicePort: 0, channel: channel)) { error in
            XCTAssertTrue(error is TunnelException, "TunnelException 以外が投げられました: \(error)")
        }
    }

    // --------------------------------------------------- TunnelOutboundQueue

    /// Kotlin 版には無い単体テスト。`FluseTunnel` 越しに back-pressure を
    /// 踏ませようとすると「TCP 側の書き込み速度を意図的に遅くする」実験環境
    /// が要り、フレークになりやすい。`TunnelOutboundQueue` は
    /// `FluseTunnel` から独立して動く actor なので、直接叩いて確かめる方が
    /// 確実（可視性を `private` → internal に変更した理由もここにある）。
    func testOutboundQueueAppliesBackpressureAndKeepsFifoOrder() async throws {
        let queue = TunnelOutboundQueue(capacity: 64)

        // 容量ちょうどまでは即座に積めるはず。
        for index in 0..<64 {
            let accepted = await queue.enqueue([UInt8(index)])
            XCTAssertTrue(accepted, "容量内の enqueue がブロックされました: index=\(index)")
        }

        // 満杯を超えた65個目。空きが出るまで戻ってこないはず。
        let blockedTask = Task { () -> Bool in
            await queue.enqueue([200])
        }

        // **固定時間のスリープで「積めた」と決め打ちしない。** ここでは逆に
        // 「一定時間内に完了していない」＝ブロックされていることを見る
        // （`FluseSocketTests.testCloseCalledByUsSuppressesLaterClosedAndFailureCallbacks`
        // が使っている「起きないはずのことが起きていないかを一定時間だけ
        // 観測する」手法と同じ。完了していれば back-pressure が効いて
        // いないというバグなので、ここで検出する）。
        let completedTooEarly = await waitForTaskCompletion(blockedTask, timeout: 0.3)
        XCTAssertFalse(completedTooEarly, "容量超過なのに enqueue がブロックされていません")

        // 1つ取り出して空きを作る。FIFO なら先頭（index 0）が出るはず。
        let first = await queue.dequeue()
        XCTAssertEqual([0], first)

        // 空きができたので、ブロックされていた enqueue が完了するはず。
        let accepted = await blockedTask.value
        XCTAssertTrue(accepted)

        // 残りを取り出し、追加分が先頭へ割り込まず末尾に付くことを確かめる。
        for index in 1..<64 {
            let value = await queue.dequeue()
            XCTAssertEqual([UInt8(index)], value, "index=\(index) で順序が崩れました")
        }
        let last = await queue.dequeue()
        XCTAssertEqual([200], last, "ブロックされていた要素が末尾に入っていません")
    }

    // ------------------------------------------------------------ 完了条件

    /// **Issue #92 / Task 9.4 の完了条件そのもの。** L1 相当の疎通が
    /// Swift 側でも通ることを、ダミー TCP エコーサーバへの大容量の
    /// 双方向転送で確かめる。
    ///
    /// Dart 側の L1 テスト（`tunnel_l1_integration_test.dart`）は 10MB で
    /// やっているが、あちらは実 WebSocket 越しに JVM ハーネスと繋ぐ
    /// プロセス間の計測で、フレーム1つあたりの経路が単純（ネイティブ
    /// ソケットの読み書きがそのまま流れる）。Swift 版のこのテストは
    /// `TunnelChannel` をフェイクにしている分、`FakeTunnelChannel.send`
    /// を経由する `actor` 越しの `await` が TCP→WebSocket 方向の
    /// フレームごとに挟まる（`readBufferLength` = 64KiB 区切り）。
    /// 実測したところ 4MiB で往復（合計 8MiB 相当の転送）が数秒で終わり、
    /// 10MiB でも安定して終わったため、「完全一致」という完了条件を
    /// 満たしつつ CI で毎回安定して終わる量として 8MiB を採用する。
    func testLargeBidirectionalEchoTransferMatchesByteForByte() async throws {
        let echo = try TcpEchoServer()
        defer { echo.stop() }
        let channel = FakeTunnelChannel()

        let totalBytes = 8 * 1024 * 1024

        try await withTunnel(port: echo.port, channel: channel, timeout: 120) { _ in
            channel.inject(.open(streamId: 1))

            let sent = payload(length: totalBytes)
            var offset = 0
            while offset < totalBytes {
                let end = min(offset + TunnelFrame.maxPayloadLength, totalBytes)
                channel.inject(.data(streamId: 1, payload: Array(sent[offset..<end])))
                offset = end
            }

            let received = try channel.collectData(streamId: 1, expectedLength: totalBytes, timeout: 90)
            XCTAssertEqual(sent, received, "大容量の双方向転送でバイト列が一致しません")
        }
    }
}

// ------------------------------------------------------------------ フィクスチャ

/// ばらけた内容にする。全部同じ値だと分割・取り違えの検出漏れになる。
private func payload(length: Int) -> [UInt8] {
    (0..<length).map { i in UInt8((i * 31 + 7) & 0xFF) }
}

/// テストヘルパー用の汎用エラー。
private struct TunnelTestError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// `FluseTunnel` を起動し、`body` の実行中だけ生かして必ず `close()` まで
/// 面倒を見る。Kotlin 版 `FluseTunnelTest.withTunnel` に相当する。
@available(iOS 13.0, macOS 11.0, *)
/// トンネルを立ててから [body] を走らせ、終わったら必ず畳む。
///
/// [timeout] は安全弁。実装側に不具合があって止まったとき、テスト
/// スイート全体を巻き込んで固まらせないために置いている。
private func withTunnel(
    port: UInt16,
    channel: FakeTunnelChannel,
    timeout: TimeInterval = 30,
    _ body: @escaping @Sendable (FluseTunnel) async throws -> Void
) async throws {
    let tunnel = try FluseTunnel(vmServicePort: port, channel: channel)
    await tunnel.start()
    do {
        try await withThrowingTimeout(seconds: timeout) {
            try await body(tunnel)
        }
    } catch {
        await tunnel.close()
        throw error
    }
    await tunnel.close()
}

/// `operation` に上限時間を持たせる。Kotlin 版の `withTimeout(30_000)` に
/// 相当する。**「時間内に終わったはず」という前提のスリープではない。**
/// 実装側に不具合があって本当に止まった場合に、テストスイート全体を
/// 巻き込んで固まらせないための安全弁。
private func withThrowingTimeout(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> Void
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TunnelTestError(message: "タイムアウトしました（\(seconds)秒）")
        }
        try await group.next()
        group.cancelAll()
    }
}

/// `condition` が真になるまで待つ。`kotlinx.coroutines.yield()` を回す
/// Kotlin 版のポーリングと同じ考え方で、固定時間のスリープに賭けない。
/// `timeout` は「実装が壊れて永遠に真にならない」場合の安全弁。
private func waitUntil(
    timeout: TimeInterval = 10,
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        if await condition() { return true }
        if Date() >= deadline { return await condition() }
        await Task.yield()
    }
}

/// `task` が `timeout` 以内に完了するかどうかを見る。完了「した」ことの
/// 確認には使わない（それだけならタイムアウトを長く取って `await task.value`
/// すればよい）。ここで使うのは「完了して**いない**」ことの確認、つまり
/// ブロックされているはずの `enqueue` がまだ返っていないことを見るため。
private func waitForTaskCompletion(_ task: Task<Bool, Never>, timeout: TimeInterval) async -> Bool {
    // **`withTaskGroup` は使わない。** `withTaskGroup` はスコープを抜ける前に、
    // まだ消費していない子タスクの完了を `cancelAll()` を呼んでいても必ず
    // 待ってしまう（構造化並行性の保証で、キャンセルは協調的なので子タスク
    // 側が自発的に止まってくれない限り止まらない）。ここで待ちたいのは
    // 「`task.value` を待つ側」で、`task` はタイムアウト側が勝った後も外側で
    // ブロックされたまま（呼び出し元がこの関数の戻り値を見た**後**に
    // `dequeue()` を呼んでようやく解放される）。これを `withTaskGroup` の
    // 子タスクにすると、タイムアウト側が勝っても group 自体が `task.value`
    // の完了を待ち続けてしまい、`dequeue()` は永遠に呼ばれず本当にデッド
    // ロックする（実機で確認済み）。ここでは非構造化の `Task` を2本
    // 「投げっぱなし」で競争させ、勝った方だけ continuation を解決する。
    // 負けた方はそのまま裏で走り続けて構わない（`task` 自身は呼び出し元が
    // 引き続き所有・観測する）。
    await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        let settlement = TaskRaceSettlement(continuation: continuation)
        Task {
            _ = await task.value
            settlement.settle(true)
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            settlement.settle(false)
        }
    }
}

/// `waitForTaskCompletion` の競争を「一度だけ」解決させるためのガード。
/// `FluseTunnel.swift` の `ConnectSettlement` と同じ形（`NSLock` で守った
/// "一度だけ" ガード）。
private final class TaskRaceSettlement: @unchecked Sendable {
    private let continuation: CheckedContinuation<Bool, Never>
    private let lock = NSLock()
    private var settled = false

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    /// 先に決まった側だけを採る。二度目以降は捨てる。
    func settle(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !settled else { return }
        settled = true
        continuation.resume(returning: value)
    }
}

/// 誰も待ち受けていないポートを探す。
///
/// エフェメラルポートを取って閉じるだけでは足りない。閉じた瞬間に OS が
/// 他へ割り当てることがあり、その場合 `FluseTunnel` は接続に成功して
/// close が返らず、タイムアウトまで原因不明で止まる。実際に拒否される
/// ことを確かめてから使う（Kotlin 版 `findRefusedPort` と同じ理由・同じ
/// 手順）。確認と本番の間にはなお隙間があるが、再試行で十分に薄めている。
private func findRefusedPort(attempts: Int = 20) throws -> UInt16 {
    for _ in 0..<attempts {
        guard let candidate = try? probeEphemeralPort() else { continue }
        if isPortRefused(candidate) {
            return candidate
        }
    }
    throw TunnelTestError(message: "誰も待ち受けていないポートを \(attempts) 回試して見つけられませんでした")
}

/// 一時的にリスナーを立てて空いているポート番号だけを取り、即座に閉じる。
private func probeEphemeralPort() throws -> UInt16 {
    let listener = try NWListener(using: .tcp, on: .any)
    let ready = DispatchSemaphore(value: 0)
    let stateLock = NSLock()
    var boundSuccessfully = false
    listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
            stateLock.withLock { boundSuccessfully = true }
            ready.signal()
        case .failed, .cancelled:
            // **bind 自体の失敗もここで起こす。** 以前は `.ready` しか
            // 見ておらず、bind に失敗した場合でも `ready.wait` が意味なく
            // 上限の5秒を丸ごと待ってしまっていた。`findRefusedPort` は
            // これを最大20回繰り返すため、bind が失敗し続ける環境では
            // テストスイート全体を100秒近く止めてしまう本物のハングに
            // なっていた（サンドボックス化された CI 実行環境で実際に
            // 確認した不具合）。
            ready.signal()
        default:
            break
        }
    }
    // **`newConnectionHandler` を設定しないと bind 自体が `EINVAL` で
    // 失敗する環境がある。** サンドボックス化された実行環境で実機
    // 確認済み（`newConnectionHandler` を設定した `TcpEchoServer` の
    // listener は同条件で毎回 bind できている）。ここでは接続を受け付ける
    // 気は無い（ポートを一瞬確保して閉じるだけ）が、bind を成立させる
    // ためにハンドラそのものは必要なので、来たら即座に畳むだけにする。
    listener.newConnectionHandler = { connection in
        connection.cancel()
    }
    let queue = DispatchQueue(label: "dev.fluse.runtime.test.port-probe")
    listener.start(queue: queue)
    defer { listener.cancel() }

    guard
        ready.wait(timeout: .now() + 5) == .success,
        stateLock.withLock({ boundSuccessfully }),
        let port = listener.port?.rawValue
    else {
        throw TunnelTestError(message: "ポートの確保に失敗しました")
    }
    return port
}

/// `port` へ接続しようとして拒否されるか（≒誰も待ち受けていないか）。
private func isPortRefused(_ port: UInt16, timeoutMs: Int = 200) -> Bool {
    guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
    let connection = NWConnection(host: NWEndpoint.Host(FluseTunnel.loopbackHost), port: nwPort, using: .tcp)
    let semaphore = DispatchSemaphore(value: 0)
    var refused = false
    let queue = DispatchQueue(label: "dev.fluse.runtime.test.port-probe.connect")
    connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
            refused = false
            semaphore.signal()
        case .failed, .cancelled:
            refused = true
            semaphore.signal()
        default:
            break
        }
    }
    connection.start(queue: queue)
    if semaphore.wait(timeout: .now() + .milliseconds(timeoutMs)) == .timedOut {
        // 応答が無い＝繋がらなかった、として扱う。
        refused = true
    }
    connection.cancel()
    return refused
}

private extension NSLock {
    /// `lock()`/`unlock()` を async 関数の本体で直接呼ぶと、Swift 6
    /// 言語モードではコンパイルエラーになる（`noasync` 指定のため）。
    /// 同期のクロージャにくるむことで、async 関数側からは「同期関数を
    /// 呼んでいるだけ」にする。
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

// -------------------------------------------------------------- FakeChannel

/// WebSocket の代わり。注入したフレームを流し、送られたフレームを溜める。
///
/// Kotlin 版 `FluseTunnelTest.FakeChannel` の Swift 版。`TunnelChannel` の
/// `incoming` は `AsyncThrowingStream` なので、`inject`/`closeIncoming`/
/// `failIncoming` はその `Continuation` を直接叩く。
@available(iOS 13.0, macOS 11.0, *)
private final class FakeTunnelChannel: TunnelChannel {
    let incoming: AsyncThrowingStream<[UInt8], Error>
    private let continuation: AsyncThrowingStream<[UInt8], Error>.Continuation

    private let sentLock = NSLock()
    private var sentFrames: [TunnelFrame] = []
    private let sentSemaphore = DispatchSemaphore(value: 0)

    /// 送信を失敗させる。中継が畳まれることを確かめるために使う。
    private let failLock = NSLock()
    private var failSendFlag = false
    var failSend: Bool {
        get { failLock.lock(); defer { failLock.unlock() }; return failSendFlag }
        set { failLock.lock(); failSendFlag = newValue; failLock.unlock() }
    }

    private let failedAttemptsLock = NSLock()
    private var failedAttemptsCount = 0

    /// 失敗した送信の試行回数。
    ///
    /// 失敗した送信は `sentFrames` に何も残さないので、「何が送られたか」
    /// だけを見ていると**送ろうとしたかどうかを区別できない**。回数を数える。
    var failedSendCount: Int {
        failedAttemptsLock.lock(); defer { failedAttemptsLock.unlock() }
        return failedAttemptsCount
    }

    /// streamId ごとの受信済みバイト列。`collectData` の呼び出しをまたいで
    /// 保持する。**他ストリームのフレームは捨てずに溜める。** 捨てると、
    /// 複数ストリームを順に検証したときに後のストリームの分が消えて、
    /// テストだけが落ちる。
    private var pending: [UInt32: [UInt8]] = [:]
    private let drainLock = NSLock()

    init() {
        var capturedContinuation: AsyncThrowingStream<[UInt8], Error>.Continuation!
        incoming = AsyncThrowingStream { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation
    }

    func send(_ frame: [UInt8]) async throws {
        if failSend {
            failedAttemptsLock.withLock { failedAttemptsCount += 1 }
            throw TunnelTestError(message: "送信できません")
        }
        let decoded = try TunnelFrame.decode(frame)
        sentLock.withLock { sentFrames.append(decoded) }
        sentSemaphore.signal()
    }

    /// サーバから届いたことにする。
    func inject(_ frame: TunnelFrame) {
        continuation.yield((try? frame.encode()) ?? [])
    }

    /// サーバが正常に切断したことにする。
    func closeIncoming() {
        continuation.finish()
    }

    /// サーバとの受信がエラーで終わったことにする。
    func failIncoming(_ error: Error) {
        continuation.finish(throwing: error)
    }

    /// 次に送られたフレームを取り出す。来なければ nil。
    func next(timeout: TimeInterval = 5) -> TunnelFrame? {
        if sentSemaphore.wait(timeout: .now() + timeout) == .timedOut {
            return nil
        }
        sentLock.lock(); defer { sentLock.unlock() }
        guard !sentFrames.isEmpty else { return nil }
        return sentFrames.removeFirst()
    }

    /// 溜まっているフレームを覗く。無ければ nil（待たない）。
    func poll() -> TunnelFrame? {
        if sentSemaphore.wait(timeout: .now()) == .timedOut {
            return nil
        }
        sentLock.lock(); defer { sentLock.unlock() }
        guard !sentFrames.isEmpty else { return nil }
        return sentFrames.removeFirst()
    }

    /// 指定 streamId の `data` を集めて連結する。
    ///
    /// 分割は中継側の都合なので、フレーム数ではなく**再結合したバイト列**
    /// で判定する。
    func collectData(streamId: UInt32, expectedLength: Int, timeout: TimeInterval = 15) throws -> [UInt8] {
        drainLock.lock()
        defer { drainLock.unlock() }

        let deadline = Date().addingTimeInterval(timeout)
        while (pending[streamId]?.count ?? 0) < expectedLength {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0, let frame = next(timeout: remaining) else {
                throw TunnelTestError(message: "streamId=\(streamId) の data 待ちがタイムアウトしました")
            }
            if frame.opcode != .data {
                if frame.streamId == streamId {
                    throw TunnelTestError(message: "\(streamId) が \(frame.opcode.wireName) で終わりました")
                }
                continue
            }
            pending[frame.streamId, default: []].append(contentsOf: frame.payload)
        }

        let buffer = pending[streamId] ?? []
        let result = Array(buffer.prefix(expectedLength))
        pending[streamId] = Array(buffer.dropFirst(expectedLength))
        return result
    }
}

// --------------------------------------------------------------- EchoServer

/// 受け取ったバイト列をそのまま返すだけの TCP サーバ。
///
/// `LocalWebSocketTestServer.swift` と同じ `Network.framework` の流儀で
/// 組む（Kotlin 版 `FluseTunnelTest.EchoServer` の Swift 版）。
@available(iOS 13.0, macOS 11.0, *)
private final class TcpEchoServer {
    /// 受け付けた1接続。閉じたかどうかを状態通知から拾って保持する。
    private final class Accepted {
        let connection: NWConnection
        private let lock = NSLock()
        private var closedFlag = false

        init(_ connection: NWConnection) {
            self.connection = connection
        }

        var isClosed: Bool {
            lock.lock(); defer { lock.unlock() }
            return closedFlag
        }

        func markClosed() {
            lock.lock(); closedFlag = true; lock.unlock()
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.fluse.runtime.test.tcp-echo")

    private let acceptedLock = NSLock()
    private var accepted: [Accepted] = []

    private let stopLock = NSLock()
    private var stopped = false

    private(set) var port: UInt16 = 0

    init() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener

        let readySemaphore = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { readySemaphore.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let entry = Accepted(connection)
            self.acceptedLock.lock()
            self.accepted.append(entry)
            self.acceptedLock.unlock()

            connection.stateUpdateHandler = { state in
                switch state {
                case .cancelled, .failed:
                    entry.markClosed()
                default:
                    break
                }
            }
            connection.start(queue: self.queue)
            self.echoLoop(connection)
        }
        listener.start(queue: queue)

        guard
            readySemaphore.wait(timeout: .now() + 5) == .success,
            let boundPort = listener.port?.rawValue
        else {
            throw TunnelTestError(message: "TCP エコーサーバの起動に失敗しました")
        }
        port = boundPort
    }

    /// 受け付けた接続の数。
    var connectionCount: Int {
        acceptedLock.lock(); defer { acceptedLock.unlock() }
        return accepted.count
    }

    private func echoLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                connection.send(
                    content: data,
                    completion: .contentProcessed { [weak self] sendError in
                        guard let self else { return }
                        if sendError == nil, !isComplete {
                            self.echoLoop(connection)
                        } else {
                            // **相手が閉じた／送信に失敗した場合はここで畳む。**
                            // `NWConnection` は相手からの FIN/エラーだけでは
                            // `.cancelled`/`.failed` に自動で遷移しない
                            // （`stateUpdateHandler` はローカルで `cancel()`
                            // を呼んだときの通知が主）。畳まずに放置すると
                            // `Accepted.isClosed` が立たず、
                            // `awaitAllClosed` が実際には閉じているのに
                            // 気づけない。
                            connection.cancel()
                        }
                    }
                )
                return
            }
            if error == nil, !isComplete {
                self.echoLoop(connection)
            } else {
                // EOF（相手が閉じた）またはエラー。上と同じ理由で畳む。
                connection.cancel()
            }
        }
    }

    /// 受け付けた接続がすべて閉じているか。
    func allClosed() -> Bool {
        acceptedLock.lock(); defer { acceptedLock.unlock() }
        return accepted.allSatisfy { $0.isClosed }
    }

    /// すべて閉じるまで待つ。上限は `timeout` が担保する。
    func awaitAllClosed(timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if allClosed() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return allClosed()
    }

    /// 後始末。二重に呼んでも安全。
    func stop() {
        stopLock.lock()
        guard !stopped else { stopLock.unlock(); return }
        stopped = true
        stopLock.unlock()

        acceptedLock.lock()
        let all = accepted
        acceptedLock.unlock()
        all.forEach { $0.connection.cancel() }
        listener.cancel()
    }
}
