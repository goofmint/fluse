import Foundation
import Network

@testable import fluse_runtime

/**
 * テストだけのために最小限の WebSocket サーバを立てる。
 *
 * Kotlin 側の `FluseConnectionServerTest.kt` は OkHttp 付属の
 * `MockWebServer` を使って実際に WebSocket を張っているが、iOS/Swift の
 * `URLSessionWebSocketTask` にはそれに相当する定番のテスト用サーバが無い。
 * ここでは OS 標準の `Network.framework`（`NWListener` + `NWProtocolWebSocket`）
 * だけで最小限のサーバを組み、`URLSessionFluseSocketFactory` が実際の
 * WebSocket ハンドシェイクの上で動くことを確かめる。
 *
 * **`URLSessionWebSocketTask` を差し込む相手として使うだけ。** 設計 §2.2.1 の
 * ワイヤ表現より複雑なことはしない。
 */
final class LocalWebSocketTestServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "dev.fluse.runtime.test.ws-server")

    private let connectionsLock = NSLock()
    private var connectionsList: [ServerPeer] = []
    private let connectionSemaphore = DispatchSemaphore(value: 0)

    private(set) var port: UInt16 = 0

    var url: String { "ws://127.0.0.1:\(port)/ws" }

    /// 立ち上げる。`deinit` を待たず、必ず `stop()` で片付けること。
    func start() throws {
        let tcpOptions = NWProtocolTCP.Options()
        let params = NWParameters(tls: nil, tcp: tcpOptions)
        let wsOptions = NWProtocolWebSocket.Options()
        // ping/pong は設計上サーバ側の制御メッセージで行う（`FluseSocket.swift`
        // 冒頭のコメント参照）。プロトコルレベルの ping には応じるだけにして、
        // 自分からは送らない。
        wsOptions.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let listener = try NWListener(using: params, on: .any)
        self.listener = listener

        let readySemaphore = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                readySemaphore.signal()
            case let .failed(error):
                os_log_test("LocalWebSocketTestServer failed: \(error)")
                self?.connectionSemaphore.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let peer = ServerPeer(connection: connection, queue: self.queue)
            self.connectionsLock.lock()
            self.connectionsList.append(peer)
            self.connectionsLock.unlock()
            peer.start()
            self.connectionSemaphore.signal()
        }
        listener.start(queue: queue)

        guard readySemaphore.wait(timeout: .now() + 5) == .success else {
            throw LocalWebSocketTestServerError.startTimedOut
        }
        guard let boundPort = listener.port?.rawValue else {
            throw LocalWebSocketTestServerError.startTimedOut
        }
        port = boundPort
    }

    /// [index] 番目（0始まり）に繋いできた端末側を返す。まだ繋いでいなければ
    /// [timeout] まで待つ。来なければ nil。
    func peer(_ index: Int = 0, timeout: TimeInterval = 5) -> ServerPeer? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            connectionsLock.lock()
            let value = connectionsList.count > index ? connectionsList[index] : nil
            connectionsLock.unlock()
            if let value { return value }

            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            _ = connectionSemaphore.wait(timeout: .now() + min(remaining, 0.05))
        }
    }

    /// 後始末。開いている接続をすべて切り、リスナーを止める。
    func stop() {
        connectionsLock.lock()
        let all = connectionsList
        connectionsLock.unlock()
        all.forEach { $0.cancel() }
        listener?.cancel()
        listener = nil
    }
}

enum LocalWebSocketTestServerError: Error {
    case startTimedOut
}

/// 端末から届いた制御メッセージを溜め、こちらからも送れるサーバ側の1本の接続。
///
/// 移植元の `FluseConnectionServerTest.kt` の `ServerSide`（`WebSocketListener`）に相当する。
final class ServerPeer {
    private let connection: NWConnection
    private let queue: DispatchQueue

    private let receivedLock = NSLock()
    private var receivedMessages: [FluseMessage] = []
    private let receivedSemaphore = DispatchSemaphore(value: 0)

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.start(queue: queue)
        receiveLoop()
    }

    private func receiveLoop() {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if
                let data,
                let context,
                let metadata = context.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata,
                metadata.opcode == .text,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let message = try? FluseMessageDecoder.fromJson(json)
            {
                self.receivedLock.lock()
                self.receivedMessages.append(message)
                self.receivedLock.unlock()
                self.receivedSemaphore.signal()
            }
            // エラーでも、閉じた直後の1回はここに来る。次を待たず終わる。
            guard error == nil else { return }
            self.receiveLoop()
        }
    }

    /// 次に届いた制御メッセージ。来なければ nil。
    func take(timeout: TimeInterval = 5) -> FluseMessage? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            receivedLock.lock()
            if !receivedMessages.isEmpty {
                let message = receivedMessages.removeFirst()
                receivedLock.unlock()
                return message
            }
            receivedLock.unlock()

            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            _ = receivedSemaphore.wait(timeout: .now() + min(remaining, 0.05))
        }
    }

    func send(_ message: FluseMessage) {
        let data = try! JSONSerialization.data(withJSONObject: message.toJson())
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "fluse-test-send", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed({ _ in }))
    }

    /// 正常な WebSocket の close フレームで閉じる。端末は切断として扱う。
    func closeGracefully() {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .protocolCode(.normalClosure)
        let context = NWConnection.ContentContext(identifier: "fluse-test-close", metadata: [metadata])
        connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed({ _ in }))
    }

    /// TCP ごと切る。`closeGracefully()` より手荒だが、確実に切断として届く。
    func cancel() {
        connection.cancel()
    }
}

/// `os_log` を直接使うとテストログの体裁が崩れるので、標準エラーに逃がす。
private func os_log_test(_ message: String) {
    FileHandle.standardError.write(Data("[LocalWebSocketTestServer] \(message)\n".utf8))
}
