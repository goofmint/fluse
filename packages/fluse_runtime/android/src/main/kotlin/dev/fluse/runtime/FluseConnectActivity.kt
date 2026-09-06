package dev.fluse.runtime

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.util.Log
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import dev.fluse.protocol.FluseMessage
import dev.fluse.protocol.RejectCode
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * ペアリング画面（設計 §2.2.5）。
 *
 * QR を読むか、手で入力してもらい、[FluseConnection] に渡して閉じる。
 *
 * **カメラを前提にしない。** 権限を断られる端末もエミュレータもある。
 * どちらの道からも同じ [FluseConnectRequest] に均してから先へ進む。
 */
class FluseConnectActivity :
    ComponentActivity(),
    FluseConnectionListener {
    companion object {
        private const val TAG = FluseRuntimePlugin.TAG

        /** この画面を開く。 */
        fun intentFor(context: Context): Intent =
            Intent(context, FluseConnectActivity::class.java).apply {
                // 画面を積み上げない。何度も開くと戻るたびに QR を求められる。
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            }
    }

    private lateinit var scanPane: View
    private lateinit var manualPane: View
    private lateinit var previewView: PreviewView
    private lateinit var scanMessage: TextView
    private lateinit var manualMessage: TextView
    private lateinit var hostField: EditText
    private lateinit var portField: EditText
    private lateinit var tokenField: EditText

    /** デコードは重い。プレビューと同じスレッドに載せない。 */
    private var analysisExecutor: ExecutorService? = null

    private var cameraProvider: ProcessCameraProvider? = null

    /** 受け入れられなかった QR の後で読み取りを再開するために持つ。 */
    private var analyzer: FluseQrAnalyzer? = null

    /** assets から読む素性。読めなければペアリングは成立しない。 */
    private var appInfo: FluseAppInfo? = null

    private var store: FluseStore? = null

    /** 繋ぎに行っている間は次の読み取りを受け付けない。 */
    @Volatile
    private var connecting = false

    /**
     * `accept` まで届いたか。
     *
     * 届く前の切断は「繋がらなかった」。届いた後の切断は
     * [FluseConnection] が自分で繋ぎ直すので、この画面では何もしない。
     */
    @Volatile
    private var established = false

    private val requestCamera =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (granted) {
                startCamera()
            } else {
                // 断られても行き止まりにしない。手で入れれば繋げる。
                showManual(getString(R.string.fluse_error_no_camera))
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.fluse_connect_activity)

        scanPane = findViewById(R.id.fluse_scan_pane)
        manualPane = findViewById(R.id.fluse_manual_pane)
        previewView = findViewById(R.id.fluse_preview)
        scanMessage = findViewById(R.id.fluse_scan_message)
        manualMessage = findViewById(R.id.fluse_manual_message)
        hostField = findViewById(R.id.fluse_host)
        portField = findViewById(R.id.fluse_port)
        tokenField = findViewById(R.id.fluse_token)

        findViewById<Button>(R.id.fluse_to_manual).setOnClickListener {
            showManual(getString(R.string.fluse_manual_hint))
        }
        findViewById<Button>(R.id.fluse_connect).setOnClickListener { submitManual() }

        appInfo =
            try {
                FluseAppInfo.load(this)
            } catch (e: Exception) {
                // **既定値で埋めない。** 素性が無ければ hello を組み立てられず、
                // どのサーバへ繋いでも断られる。
                Log.e(TAG, "Preview App の情報を読めませんでした: $e")
                null
            }

        if (appInfo == null) {
            scanMessage.text = getString(R.string.fluse_error_app_info)
            return
        }

        if (hasCamera()) {
            requestCamera.launch(Manifest.permission.CAMERA)
        } else {
            // エミュレータとカメラの無い端末。最初から手入力を出す。
            showManual(getString(R.string.fluse_error_no_camera))
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        cameraProvider?.unbindAll()
        analysisExecutor?.shutdown()
        // **listener を外す。** 閉じた画面を掴んだままだと、以後の接続の
        // 通知が届き続け、Activity が解放されない。
        FluseConnection.instance?.removeListener(this)
    }

    // ------------------------------------------------------------------ カメラ

    private fun hasCamera(): Boolean =
        packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)

    private fun startCamera() {
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener({
            val provider =
                try {
                    future.get()
                } catch (e: Exception) {
                    Log.w(TAG, "カメラを開けませんでした: $e")
                    showManual(getString(R.string.fluse_error_no_camera))
                    return@addListener
                }
            bindCamera(provider)
        }, ContextCompat.getMainExecutor(this))
    }

    private fun bindCamera(provider: ProcessCameraProvider) {
        cameraProvider = provider
        val executor = Executors.newSingleThreadExecutor()
        analysisExecutor = executor

        val preview =
            Preview.Builder().build().also {
                it.setSurfaceProvider(previewView.surfaceProvider)
            }
        val analysis =
            ImageAnalysis.Builder()
                // **溜めない。** デコードが遅れたコマを追いかけると、
                // 画面と手元がずれて狙いを定められなくなる。
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
                .also {
                    val created = FluseQrAnalyzer(::onDecoded)
                    analyzer = created
                    it.setAnalyzer(executor, created)
                }

        try {
            provider.unbindAll()
            provider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
        } catch (e: Exception) {
            Log.w(TAG, "カメラを使えませんでした: $e")
            showManual(getString(R.string.fluse_error_no_camera))
        }
    }

    /** 解析スレッドから呼ばれる。画面に触るのでメインへ戻す。 */
    private fun onDecoded(text: String) {
        runOnUiThread {
            if (connecting) {
                return@runOnUiThread
            }
            when (val result = FluseConnectUri.parse(text)) {
                is FluseConnectResult.Rejected -> {
                    scanMessage.text = messageFor(result.error)
                    // 読み取りを止めたままにしない。次の QR を待つ。
                    analyzer?.resume()
                }

                is FluseConnectResult.Accepted -> accept(result.request)
            }
        }
    }

    // ---------------------------------------------------------------- 手入力

    private fun showManual(message: String) {
        runOnUiThread {
            cameraProvider?.unbindAll()
            scanPane.visibility = View.GONE
            manualPane.visibility = View.VISIBLE
            manualMessage.text = message
        }
    }

    private fun submitManual() {
        val info = appInfo ?: return
        if (connecting) {
            return
        }
        val result =
            FluseConnectUri.fromManualInput(
                host = hostField.text.toString(),
                port = portField.text.toString(),
                token = tokenField.text.toString(),
                appInfo = info,
            )
        when (result) {
            is FluseConnectResult.Rejected -> manualMessage.text = messageFor(result.error)
            is FluseConnectResult.Accepted -> accept(result.request)
        }
    }

    // ---------------------------------------------------------------- 接続

    private fun accept(request: FluseConnectRequest) {
        val info = appInfo ?: return

        // 繋ぎに行く前に噛み合うか見る。往復を省いて理由をその場で出す。
        // **サーバ側の検証を省いたわけではない。** 端末の値は書き換えられる。
        FluseConnectUri.verify(request, info)?.let {
            showError(messageFor(it))
            analyzer?.resume()
            return
        }

        connecting = true
        val opened =
            store ?: try {
                FluseStore.open(this).also { store = it }
            } catch (e: Exception) {
                Log.w(TAG, "設定を読めませんでした: $e")
                connecting = false
                showError(getString(R.string.fluse_error_app_info))
                return
            }

        try {
            val connection = FluseConnection.getOrCreate(application, opened)
            // 赤画面とバッジもこの接続を見る。ペアリングから入った時に
            // 繋ぎ込みが漏れないよう、ここでも呼ぶ。
            FluseSurfaces.listenTo(connection)
            connection.addListener(this)
            // **例外の外に置かない。** connect はその場でソケットを開き、
            // 繋ぎ先が URL として壊れていれば投げる。ここで抜けると
            // connecting が立ったままになり、二度と入力を受け付けない。
            connection.connect(request.endpoint(), pairingToken = request.pairingToken)
        } catch (e: Exception) {
            Log.w(TAG, "接続を開始できませんでした: $e")
            failed(getString(R.string.fluse_error_connect))
        }
    }

    /** 繋がらなかった。もう一度やり直せる状態に戻す。 */
    private fun failed(message: String) {
        runOnUiThread {
            connecting = false
            analyzer?.resume()
            showError(message)
        }
    }

    // ------------------------------------------- FluseConnectionListener

    override fun onConnected(sessionId: String) {
        established = true
        // 繋がったら用済み。**接続は切らない。** 持ち主は Application
        // スコープの FluseConnection であって、この画面ではない。
        runOnUiThread { finish() }
    }

    override fun onRejected(
        code: String,
        message: String,
    ) = failed(messageFor(RejectCode.tryParse(code)))

    override fun onNeedsPairing(reason: String) = failed(getString(R.string.fluse_error_auth))

    override fun onDisconnected() {
        // **受理される前の切断は失敗。** ここで戻さないと connecting が
        // 立ったままになり、やり直せなくなる。受理後の切断は
        // FluseConnection が自分で繋ぎ直すので、この画面は何もしない。
        if (established) {
            return
        }
        failed(getString(R.string.fluse_error_connect))
    }

    override fun onMessage(message: FluseMessage) = Unit

    // ---------------------------------------------------------------- 表示

    private fun showError(message: String) {
        if (manualPane.visibility == View.VISIBLE) {
            manualMessage.text = message
        } else {
            scanMessage.text = message
        }
    }

    private fun messageFor(error: FluseConnectError): String =
        when (error) {
            FluseConnectError.NOT_FLUSE -> getString(R.string.fluse_error_not_fluse)
            FluseConnectError.MALFORMED -> getString(R.string.fluse_error_malformed)
            FluseConnectError.PROTOCOL_MISMATCH -> getString(R.string.fluse_error_protocol)
            FluseConnectError.PROJECT_MISMATCH -> getString(R.string.fluse_error_project)
            FluseConnectError.REVISION_MISMATCH -> getString(R.string.fluse_error_revision)
        }

    /** 未知のコードでも黙らない。理由が出ないと切り分けができない。 */
    private fun messageFor(code: RejectCode?): String =
        when (code) {
            RejectCode.AUTH_FAILED -> getString(R.string.fluse_error_auth)
            RejectCode.PROJECT_MISMATCH -> getString(R.string.fluse_error_project)
            RejectCode.REVISION_MISMATCH -> getString(R.string.fluse_error_revision)
            RejectCode.PROTOCOL_MISMATCH -> getString(R.string.fluse_error_protocol)
            RejectCode.APP_OUTDATED -> getString(R.string.fluse_error_revision)
            RejectCode.TOO_MANY_DEVICES -> getString(R.string.fluse_error_too_many)
            null -> getString(R.string.fluse_error_malformed)
        }
}
