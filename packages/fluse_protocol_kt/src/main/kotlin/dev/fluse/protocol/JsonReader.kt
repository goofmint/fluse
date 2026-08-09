package dev.fluse.protocol

import java.math.BigDecimal
import java.math.BigInteger
import org.json.JSONArray
import org.json.JSONObject

/**
 * JSON から型付きの値を取り出す小道具。
 *
 * 「無い」と「型が違う」を別のメッセージで報告する。片方に丸めると、
 * 壊れたメッセージの原因が追えなくなる。Dart 側の `JsonReader` と同じ規則。
 */
internal class JsonReader(private val json: JSONObject) {
    companion object {
        /** JSON が正確に表せる整数の上限（2^53 - 1）。 */
        const val MAX_SAFE_INTEGER = 9007199254740991L

        /** 同じく下限。 */
        const val MIN_SAFE_INTEGER = -9007199254740991L

        private val SAFE_MAX: BigInteger = BigInteger.valueOf(MAX_SAFE_INTEGER)
        private val SAFE_MIN: BigInteger = BigInteger.valueOf(MIN_SAFE_INTEGER)

        /**
         * 安全整数の最大桁数（9007199254740991 は 16 桁）。
         *
         * これを超える [BigDecimal] は、値を展開する前に範囲外と決められる。
         */
        private const val MAX_SAFE_DIGITS = 16L
    }

    /** キーが存在し、かつ JSON の null でもないか。 */
    private fun has(field: String): Boolean = json.has(field) && !json.isNull(field)

    fun requireString(type: String, field: String): String {
        if (!has(field)) throw FluseProtocolException.missingField(type, field)
        val value = json.get(field)
        if (value !is String) {
            throw FluseProtocolException.wrongType(type, field, "文字列", value)
        }
        return value
    }

    /** 省略可能な文字列。キーが無い場合と null の場合はどちらも null。 */
    fun optionalString(type: String, field: String): String? =
        if (!has(field)) null else requireString(type, field)

    /**
     * 必須の整数。
     *
     * JSON の数値は整数型で来るとは限らない。`1.0` や `1e3` のような
     * 小数表記は Dart 側では `double` になり、**org.json では
     * [BigDecimal] になる**（`Double` ではない）。どちらも整数として
     * 表せる場合だけ受け入れる。Dart 側が通す値を Kotlin 側が弾いたら
     * ワイヤ互換が崩れる。
     *
     * `Double` の枝も残す。`JSONObject.put("x", 1.0)` のように
     * 組み立てられた JSON はテキストを経由せず `Double` のまま届く。
     */
    fun requireInt(type: String, field: String): Long {
        if (!has(field)) throw FluseProtocolException.missingField(type, field)
        return when (val value = json.get(field)) {
            is Int -> requireSafeRange(type, field, value.toLong())
            is Long -> requireSafeRange(type, field, value)
            is Double -> {
                if (!value.isFinite() || value != Math.floor(value)) {
                    throw FluseProtocolException.wrongType(type, field, "整数", value)
                }
                if (value < MIN_SAFE_INTEGER || value > MAX_SAFE_INTEGER) {
                    throw FluseProtocolException.wrongType(
                        type, field, "JSON が正確に表せる整数", value,
                    )
                }
                value.toLong()
            }
            is BigDecimal -> {
                // 整数部の桁数を先に見る。`1E+2000000000` を素直に展開すると
                // 巨大な BigInteger を確保して落ちる。桁数は unscaledValue を
                // 展開せずに求まるので、確保する前に弾ける。
                if (value.precision().toLong() - value.scale().toLong() > MAX_SAFE_DIGITS) {
                    throw FluseProtocolException.wrongType(
                        type, field, "JSON が正確に表せる整数", value,
                    )
                }
                // 1.0 や 1E+3 は整数に落ちる。7.5 のように小数部が残る値は
                // toBigIntegerExact が ArithmeticException を投げる。
                val integral = try {
                    value.toBigIntegerExact()
                } catch (_: ArithmeticException) {
                    throw FluseProtocolException.wrongType(type, field, "整数", value)
                }
                if (integral < SAFE_MIN || integral > SAFE_MAX) {
                    throw FluseProtocolException.wrongType(
                        type, field, "JSON が正確に表せる整数", value,
                    )
                }
                integral.toLong()
            }
            else -> throw FluseProtocolException.wrongType(type, field, "整数", value)
        }
    }

    /** 省略可能な整数。キーが無い場合と null の場合はどちらも null。 */
    fun optionalInt(type: String, field: String): Long? =
        if (!has(field)) null else requireInt(type, field)

    /** 必須の配列。 */
    fun requireArray(type: String, field: String): JSONArray {
        if (!has(field)) throw FluseProtocolException.missingField(type, field)
        val value = json.get(field)
        if (value !is JSONArray) {
            throw FluseProtocolException.wrongType(type, field, "配列", value)
        }
        return value
    }

    private fun requireSafeRange(type: String, field: String, value: Long): Long {
        if (value < MIN_SAFE_INTEGER || value > MAX_SAFE_INTEGER) {
            throw FluseProtocolException.wrongType(
                type, field, "JSON が正確に表せる整数", value,
            )
        }
        return value
    }
}
