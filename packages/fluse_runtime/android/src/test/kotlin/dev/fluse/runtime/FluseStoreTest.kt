package dev.fluse.runtime

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

internal class FluseStoreTest {
    private fun store() = FluseStore(MemoryBacking())

    @Test
    fun `代替 deviceId は一度作ったら変わらない`() {
        // 起動のたびに変わると、サーバ側の登録が積み上がる。
        val store = store()

        assertEquals(store.fallbackDeviceId(), store.fallbackDeviceId())
    }

    @Test
    fun `代替 deviceId は端末ごとに違う`() {
        // 同じ値に落ちると、別々の端末が1台に見える。
        assertNotEquals(store().fallbackDeviceId(), store().fallbackDeviceId())
    }

    @Test
    fun `代替 deviceId は16桁の16進`() {
        // ANDROID_ID 由来の deviceId と同じ形にしておく。
        val id = store().fallbackDeviceId()

        assertEquals(DeviceIdentity.DEVICE_ID_LENGTH, id.length)
        assertTrue(id.all { it in '0'..'9' || it in 'a'..'f' }, id)
    }

    @Test
    fun `空を書いたら消える`() {
        // 空文字が残ると hasDeviceToken が true になってしまう。
        val store = store()
        store.deviceToken = "t"

        store.deviceToken = ""

        assertNull(store.deviceToken)
        assertFalse(store.hasDeviceToken())
    }

    @Test
    fun `トークンと接続先が揃って初めて繋ぎ直せる`() {
        val store = store()
        store.deviceToken = "t"

        assertFalse(store.hasLastServer())

        store.lastHost = "192.168.1.2"
        store.lastPort = 8080

        assertTrue(store.hasLastServer())
    }

    @Test
    fun `ポート未設定は接続先が無い扱い`() {
        // ホストだけでは繋ぎようが無い。
        val store = store()
        store.lastHost = "192.168.1.2"

        assertEquals(FluseStore.NO_PORT, store.lastPort)
        assertFalse(store.hasLastServer())
    }

    @Test
    fun `clear で登録が消える`() {
        val store = store()
        store.deviceToken = "t"
        store.lastHost = "192.168.1.2"
        store.lastPort = 8080

        store.clear()

        assertFalse(store.hasDeviceToken())
        assertFalse(store.hasLastServer())
    }

    @Test
    fun `toString にトークンを含めない`() {
        // 例外文やログに混ざると漏れる。
        val store = store()
        store.deviceToken = "s3cr3t-token"

        assertFalse(store.toString().contains("s3cr3t"), store.toString())
    }

    @Test
    fun `メモリだけの置き場は永続ではない`() {
        // 平文で残すより、起動のたびにペアリングさせる方がよい。
        assertFalse(store().isPersistent)
    }
}
