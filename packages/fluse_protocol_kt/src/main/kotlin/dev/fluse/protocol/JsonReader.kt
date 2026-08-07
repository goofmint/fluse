package dev.fluse.protocol

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
     * JSON の数値は `Double` で来ることがある（`1.0` など）。整数として
     * 表せる場合だけ受け入れる。範囲も検査する。
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
