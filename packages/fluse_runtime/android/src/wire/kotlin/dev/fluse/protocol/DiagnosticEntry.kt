package dev.fluse.protocol

import org.json.JSONObject

/**
 * ワイヤに載せるコンパイル診断1件（設計 §2.2.1 の `CompileErrorMessage`）。
 *
 * Dart 側の `DiagnosticEntry` と同じ形。
 */
class DiagnosticEntry(
    val severity: DiagnosticSeverity,
    val message: String,
    val file: String? = null,
    val line: Long? = null,
    val col: Long? = null,
) {
    /** `file:line:col` 形式。エディタから開けるようにするための表現。 */
    val location: String?
        get() {
            val path = file ?: return null
            val l = line ?: return path
            return if (col == null) "$path:$l" else "$path:$l:$col"
        }

    fun toJson(): JSONObject {
        val json = JSONObject()
        json.put("severity", severity.wireValue)
        json.put("message", message)
        file?.let { json.put("file", it) }
        line?.let { json.put("line", it) }
        col?.let { json.put("col", it) }
        return json
    }

    companion object {
        private const val TYPE = "DiagnosticEntry"

        fun fromJson(json: JSONObject): DiagnosticEntry {
            val reader = JsonReader(json)
            val rawSeverity = reader.requireString(TYPE, "severity")
            val severity = DiagnosticSeverity.tryParse(rawSeverity)
                // 深刻度が分からないとオーバーレイの出し分けができない。
                // 黙って error に丸めると、警告で赤画面になる。
                //
                // **受け取った値そのものは載せない。** severity は相手が
                // 自由に入れられるフィールドで、例外文はログに出る。
                ?: throw FluseProtocolException("$TYPE: 未知の severity")

            return DiagnosticEntry(
                severity = severity,
                message = reader.requireString(TYPE, "message"),
                file = reader.optionalString(TYPE, "file"),
                line = reader.optionalInt(TYPE, "line"),
                col = reader.optionalInt(TYPE, "col"),
            )
        }
    }

    override fun toString(): String = location?.let { "$it: $message" } ?: message
}
