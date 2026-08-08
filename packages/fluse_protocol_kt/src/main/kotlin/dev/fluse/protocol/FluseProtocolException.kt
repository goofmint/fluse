package dev.fluse.protocol

/**
 * ワイヤ表現を解釈できなかったときに投げる。
 *
 * **トークンなどの値は載せない。** このメッセージはログにも出るため、
 * `pairingToken` や `deviceToken` が混ざると漏れる。
 * 何のフィールドが、どう期待と違ったかだけを書く。
 */
class FluseProtocolException(message: String) : Exception(message) {
    companion object {
        /** 欠けているフィールドについての定型。 */
        fun missingField(type: String, field: String): FluseProtocolException =
            FluseProtocolException("$type: $field がありません")

        /**
         * 型が違うフィールドについての定型。
         *
         * 値そのものは載せず、実際の型だけを示す。
         */
        fun wrongType(
            type: String,
            field: String,
            expected: String,
            actual: Any?,
        ): FluseProtocolException =
            FluseProtocolException(
                "$type: $field が $expected ではありません（実際は ${actual?.javaClass?.simpleName ?: "null"}）",
            )
    }
}
