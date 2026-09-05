package dev.fluse.runtime

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

internal class DeviceIdentityTest {
    @Test
    fun `同じ ANDROID_ID なら同じ deviceId`() {
        // 再起動のたびに変わると、サーバ側の登録が積み上がる。
        val id = DeviceIdentity.hashAndroidId("a1b2c3d4e5f60718")

        assertEquals(id, DeviceIdentity.hashAndroidId("a1b2c3d4e5f60718"))
    }

    @Test
    fun `違う ANDROID_ID なら違う deviceId`() {
        assertNotEquals(
            DeviceIdentity.hashAndroidId("a1b2c3d4e5f60718"),
            DeviceIdentity.hashAndroidId("a1b2c3d4e5f60719"),
        )
    }

    @Test
    fun `deviceId は16桁の16進`() {
        val id = DeviceIdentity.hashAndroidId("a1b2c3d4e5f60718")

        assertEquals(DeviceIdentity.DEVICE_ID_LENGTH, id.length)
        assertTrue(id.all { it in '0'..'9' || it in 'a'..'f' }, id)
    }

    @Test
    fun `元の ANDROID_ID は含まれない`() {
        // ANDROID_ID は他のアプリとの突き合わせに使える。そのまま送らない。
        val androidId = "a1b2c3d4e5f60718"

        assertFalse(DeviceIdentity.hashAndroidId(androidId).contains(androidId))
    }

    @Test
    fun `ANDROID_ID が空でも落ちない`() {
        // 取れない端末がある。落とすとアプリごと起動しなくなる。
        assertEquals(DeviceIdentity.DEVICE_ID_LENGTH, DeviceIdentity.hashAndroidId("").length)
    }

    @Test
    fun `deviceName はメーカーと型番をつなぐ`() {
        assertEquals("Samsung SM-G991B", DeviceIdentity.deviceName("Samsung", "SM-G991B"))
    }

    @Test
    fun `型番がメーカー名で始まるなら重ねない`() {
        // "Google Google Pixel 8" にはしない。
        assertEquals("Google Pixel 8", DeviceIdentity.deviceName("Google", "Google Pixel 8"))
    }

    @Test
    fun `片方が空でも形になる`() {
        assertEquals("Pixel 8", DeviceIdentity.deviceName("", "Pixel 8"))
        assertEquals("Google", DeviceIdentity.deviceName("Google", ""))
    }
}
