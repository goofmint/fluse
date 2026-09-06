package dev.fluse.runtime.l1harness

import dev.fluse.runtime.FluseTunnel
import java.net.URI
import java.net.http.HttpClient
import java.time.Duration
import kotlin.system.exitProcess
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.future.await
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.selects.select

/**
 * 準備完了を伝える標識行。
 *
 * Dart 側はこの行を待ってから転送を始める。出す前に流し始めると、まだ
 * WebSocket が繋がっていない間の `open` が落ちて、原因の分かりにくい失敗になる。
 */
const val READY = "READY"

/** WebSocket のハンドシェイクを待つ上限。 */
private val CONNECT_TIMEOUT: Duration = Duration.ofSeconds(30)

/**
 * L1統合テスト（Task 2.5）用のハーネス。**本番経路では使わない。**
 *
 * Dart 側テストがこのプロセスを起動し、`TunnelEndpoint`(Dart) ⇄
 * [FluseTunnel](JVM) を実 WebSocket 越しに繋いで 10MB 双方向転送を検証する。
 *
 * 引数は `<wsUrl> <vmServicePort>`。
 *
 * - `wsUrl`: Dart 側が立てた WebSocket サーバの URL（`ws://127.0.0.1:<port>`）
 * - `vmServicePort`: 本物の VM Service に見立てたエコーサーバのポート
 *
 * **このパッケージを Android プラグインへ移してはいけない。**
 * `java.net.http` は Android のクラスライブラリに無い。
 */
fun main(args: Array<String>) {
    if (args.size != 2) {
        System.err.println("使い方: <wsUrl> <vmServicePort>")
        exitProcess(2)
    }
    val wsUrl = args[0]
    val vmServicePort = args[1].toIntOrNull()
    if (vmServicePort == null || vmServicePort !in 1..65535) {
        System.err.println("vmServicePort が不正です: ${args[1]}")
        exitProcess(2)
    }

    val exitCode = runBlocking {
        // FluseTunnel は渡した scope の子として動く。runBlocking の job を
        // そのまま渡すと、トンネルの後始末が終わるまで抜けられない。
        val scope = CoroutineScope(coroutineContext + SupervisorJob(coroutineContext[Job]))
        val channel = WebSocketTunnelChannel(scope)

        val tunnel = try {
            val webSocket = HttpClient.newHttpClient()
                .newWebSocketBuilder()
                .connectTimeout(CONNECT_TIMEOUT)
                .buildAsync(URI.create(wsUrl), channel)
                .await()
            channel.attach(webSocket)
            FluseTunnel(vmServicePort, channel, scope).also { it.start() }
        } catch (e: Throwable) {
            System.err.println("ハーネスの初期化に失敗しました: $e")
            // 正常経路と同じく畳む。**忘れると SupervisorJob が Active のまま
            // 残り、runBlocking が抜けられない。** プロセスが居座り、Dart 側は
            // READY を 60 秒待ってから落ちるので原因が見えなくなる。
            scope.cancel()
            return@runBlocking 1
        }

        println(READY)
        System.out.flush()

        // 標準入力の終了を「親テストが終わった」合図に使う。トンネルが
        // 生きたままでもここで畳まないと、テストが落ちたときにプロセスが残る。
        //
        // ブロッキング read は cancel では止められない。coroutine で回すと
        // runBlocking が子の完了を待って抜けられなくなるので、デーモン
        // スレッドに逃がす。
        val stdinClosed = CompletableDeferred<Unit>()
        Thread {
            @Suppress("ControlFlowWithEmptyBody")
            while (System.`in`.read() != -1) {}
            stdinClosed.complete(Unit)
        }.apply { isDaemon = true }.start()

        val failure: Throwable? = try {
            select<Unit> {
                tunnel.done.onAwait { }
                stdinClosed.onAwait { }
            }
            null
        } catch (e: Throwable) {
            // done が例外で終わると onAwait はここへ投げてくる。
            e
        }

        tunnel.close()
        // **ここで畳まないと runBlocking が抜けられない。** scope の
        // SupervisorJob は runBlocking の子で、誰も完了させないため、
        // 受信側の宙ぶらりんな coroutine ごと待ち続けることになる。
        scope.cancel()

        if (failure != null) {
            System.err.println("トンネルが異常終了しました: $failure")
            1
        } else {
            0
        }
    }

    exitProcess(exitCode)
}
