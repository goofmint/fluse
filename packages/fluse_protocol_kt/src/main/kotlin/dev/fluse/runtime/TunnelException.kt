package dev.fluse.runtime

/**
 * トンネルの中継に失敗したときに投げる。
 *
 * サーバ側 `TunnelException`（Dart）の鏡像。
 *
 * **VM Service の URI やトークンは載せない。** この文言はログに出る。
 */
class TunnelException(message: String, cause: Throwable? = null) :
    Exception(if (cause == null) "トンネル: $message" else "トンネル: $message ($cause)", cause)
