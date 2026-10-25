package ai.masko.player

import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.SystemClock
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DataSink
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSourceUtil
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.TransferListener
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.CacheWriter
import androidx.media3.datasource.cache.NoOpCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.LoadControl
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/** The clip files on a real device: what a loop reads, and a disk cache that cannot write. */
@OptIn(UnstableApi::class)
@RunWith(AndroidJUnit4::class)
class MediaTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    private fun <T> main(f: () -> T): T {
        var result: Result<T>? = null
        instrumentation.runOnMainSync { result = runCatching(f) }
        return result!!.getOrThrow()
    }

    private fun waitFor(what: String, timeoutMs: Long = 10_000, done: () -> Boolean) {
        val until = SystemClock.elapsedRealtime() + timeoutMs
        while (!done()) {
            if (SystemClock.elapsedRealtime() > until) fail("timed out waiting for $what")
            Thread.sleep(20)
        }
    }

    /** A lone clip's file, as [MediaFiles.clipFile] reads it on a real device; null when it cannot be read. */
    private fun clipFile(url: String): ClipFile? {
        val answer = AtomicReference<Result<ClipFile?>?>(null)
        main { MediaFiles.get(context).clipFile(url) { answer.set(Result.success(it)) } }
        waitFor("the file at $url") { answer.get() != null }
        return answer.get()!!.getOrThrow()
    }

    @Test
    fun aLoneClipsLengthAndSoundTrackAreReadFromItsFile() {
        val file = File(context.cacheDir, "length-red.mp4")
        context.assets.open("clips/red.mp4").use { input -> file.outputStream().use { input.copyTo(it) } }
        val retriever = MediaMetadataRetriever()
        val (expected, voiced) = try {
            retriever.setDataSource(file.path)
            Pair(
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)!!.toLong() / 1000.0,
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO) == "yes",
            )
        } finally {
            retriever.release()
        }
        assertTrue(expected > 0)
        val read = clipFile(Uri.fromFile(file).toString())!!
        assertEquals(expected, read.seconds, 0.001)
        assertEquals(voiced, read.voiced)
        assertNull(clipFile(Uri.fromFile(File(context.cacheDir, "none.mp4")).toString()))
    }

    /** Counts how often a file is opened. */
    private class Counting(private val source: DataSource, private val opens: AtomicInteger) : DataSource {
        override fun addTransferListener(transferListener: TransferListener) = source.addTransferListener(transferListener)
        override fun open(dataSpec: DataSpec): Long {
            opens.incrementAndGet()
            return source.open(dataSpec)
        }
        override fun read(buffer: ByteArray, offset: Int, length: Int) = source.read(buffer, offset, length)
        override fun getUri(): Uri? = source.uri
        override fun close() = source.close()
    }

    /** How often red.mp4 is opened for its first play, then for a second loop (a seek back to 0). */
    private fun opensForTwoLoops(loadControl: LoadControl?): Pair<Int, Int> {
        val opens = AtomicInteger()
        val ends = AtomicInteger()
        val files = DataSource.Factory { Counting(DefaultDataSource.Factory(context).createDataSource(), opens) }
        val player = main {
            ExoPlayer.Builder(context).apply { loadControl?.let(::setLoadControl) }.build().also {
                it.addListener(object : Player.Listener {
                    override fun onPlaybackStateChanged(state: Int) {
                        if (state == Player.STATE_ENDED) ends.incrementAndGet()
                    }
                })
                it.setMediaSource(ProgressiveMediaSource.Factory(files).createMediaSource(MediaItem.fromUri("asset:///clips/red.mp4")))
                it.prepare()
                it.playWhenReady = true
            }
        }
        try {
            waitFor("the first loop") { ends.get() == 1 }
            val first = opens.get()
            main { player.seekTo(0) }
            waitFor("the second loop") { ends.get() == 2 }
            return first to opens.get()
        } finally {
            main { player.release() }
        }
    }

    @Test
    fun aLoopSeeksBackInsideTheClipInMemory() {
        val (first, second) = opensForTwoLoops(clipLoadControl())
        assertEquals("the second loop reads nothing again", first, second)
        // Without the back buffer the file is read again for every loop.
        val (plainFirst, plainSecond) = opensForTwoLoops(null)
        assertTrue("$plainFirst then $plainSecond", plainSecond > plainFirst)
    }

    @Test
    fun aCacheThatCannotWriteStillGivesTheFile() {
        val dir = File(context.cacheDir, "masko-player-test-readonly").apply {
            setWritable(true, false)
            deleteRecursively()
            mkdirs()
        }
        val cache = SimpleCache(dir, NoOpCacheEvictor(), StandaloneDatabaseProvider(context))
        // The cache finishes setting up its folder on its own thread; this call waits for it.
        cache.keys
        val expected = context.assets.open("clips/red.mp4").use { it.readBytes() }
        val upstream = DefaultDataSource.Factory(context)
        fun files(sinks: DataSink.Factory?): CacheDataSource.Factory =
            CacheDataSource.Factory()
                .setCache(cache)
                .setUpstreamDataSourceFactory(upstream)
                .setCacheKeyFactory { "red" }
                .apply { if (sinks != null) setCacheWriteDataSinkFactory(sinks) }
        fun read(source: DataSource): ByteArray {
            source.open(DataSpec(Uri.parse("asset:///clips/red.mp4")))
            try {
                return DataSourceUtil.readToEnd(source)
            } finally {
                source.close()
            }
        }
        try {
            // Like a full disk: the cache can make no file.
            assertTrue(dir.setWritable(false, false))
            assertTrue("without it, a read fails", runCatching { read(files(null).createDataSource()) }.isFailure)
            assertArrayEquals(expected, read(files(tolerantCacheSink(cache)).createDataSource()))
            // A preload goes through too.
            CacheWriter(files(tolerantCacheSink(cache)).createDataSource(), DataSpec(Uri.parse("asset:///clips/red.mp4")), null, null).cache()
            assertEquals("nothing was cached", 0L, cache.getCachedBytes("red", 0, -1))
        } finally {
            dir.setWritable(true, false)
            cache.release()
            dir.deleteRecursively()
        }
    }
}
