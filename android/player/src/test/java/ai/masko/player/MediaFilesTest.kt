package ai.masko.player

import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.cache.Cache
import androidx.media3.datasource.cache.CacheDataSink
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException

@OptIn(UnstableApi::class)
class MediaFilesTest {

    @Test
    fun eachProcessHasItsOwnCacheFolder() {
        assertEquals("ai.masko.demo", processFolder("ai.masko.demo", "ai.masko.demo"))
        assertEquals("ai.masko.demo_remote", processFolder("ai.masko.demo:remote", "ai.masko.demo"))
        assertEquals("ai.masko.demo", processFolder(null, "ai.masko.demo"))
        assertEquals("ai.masko.demo", processFolder(" ", "ai.masko.demo"))
        assertEquals("a_b_c", processFolder("a/b c", "x"))
    }

    @Test
    fun cacheFailuresAreToldFromFileFailures() {
        assertTrue(isCacheFailure(CacheDataSink.CacheDataSinkException(IOException("No space left on device"))))
        assertTrue(isCacheFailure(IOException("read", Cache.CacheException("Failed to create cache directory"))))
        assertFalse(isCacheFailure(IOException("Unable to connect")))
    }

    @Test
    fun theLicensesShipInTheLibrary() {
        for (name in listOf("LICENSE", "THIRD_PARTY_NOTICES.md")) {
            val text = javaClass.classLoader!!.getResource("META-INF/ai.masko.player/$name")?.readText()
            assertNotNull("META-INF/ai.masko.player/$name", text)
        }
        val license = javaClass.classLoader!!.getResource("META-INF/ai.masko.player/LICENSE")!!.readText()
        assertTrue(license.startsWith("MIT License"))
    }
}
