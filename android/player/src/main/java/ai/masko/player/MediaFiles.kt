package ai.masko.player

import android.app.Application
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.LruCache
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DataSink
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSourceUtil
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.cache.Cache
import androidx.media3.datasource.cache.CacheDataSink
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.CacheWriter
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import java.io.File
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference

/**
 * Clip, still and sound files, one per process: remote files go through a
 * disk cache keyed by the link without its query, so a refreshed signed link
 * still finds the file cached. Each process of an app has its own cache
 * folder. A cache that cannot write (a full disk) never fails a file: it
 * plays from the network instead.
 */
@OptIn(UnstableApi::class)
internal class MediaFiles private constructor(private val context: Context) {
    /** A preload or a still that is loading. Cancelled, its callback is never called. */
    fun interface Request {
        fun cancel()
    }

    private val cache = SimpleCache(
        File(context.cacheDir, "masko-player/" + processFolder(processName(), context.packageName)),
        LeastRecentlyUsedCacheEvictor(CACHE_BYTES),
        StandaloneDatabaseProvider(context),
    )
    private val http = DefaultHttpDataSource.Factory().setAllowCrossProtocolRedirects(true)
    private val cached = CacheDataSource.Factory()
        .setCache(cache)
        .setUpstreamDataSourceFactory(http)
        .setCacheWriteDataSinkFactory(tolerantCacheSink(cache))
        .setCacheKeyFactory { spec -> fileKey(spec.uri.toString()) }
        .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
    private val local = DefaultDataSource.Factory(context, http)
    private val remoteSources = ProgressiveMediaSource.Factory(cached)
    private val localSources = ProgressiveMediaSource.Factory(local)
    private val work = Executors.newFixedThreadPool(2) { r -> Thread(r, "MaskoMediaFiles").apply { isDaemon = true } }
    private val main = Handler(Looper.getMainLooper())
    private val stills = LruCache<String, Bitmap>(8)

    /** One preload of a file, shared by everyone who asked for it (main thread). */
    private class Preload {
        val callbacks = ArrayList<(Boolean) -> Unit>()
        @Volatile var cancelled = false
        @Volatile var writer: CacheWriter? = null
    }

    private val preloading = HashMap<String, Preload>()

    fun source(url: String): MediaSource =
        (if (isRemote(url)) remoteSources else localSources).createMediaSource(MediaItem.fromUri(url))

    /**
     * Puts a remote file in the cache; [done] runs on the main thread with
     * whether the file can be read. Local files are there already.
     */
    fun preload(url: String, done: (Boolean) -> Unit): Request {
        if (!isRemote(url)) {
            val task = Runnable { done(true) }
            main.post(task)
            return Request { main.removeCallbacks(task) }
        }
        val key = fileKey(url)
        val job = preloading[key] ?: Preload().also { job ->
            preloading[key] = job
            work.execute { write(job, key, url) }
        }
        job.callbacks += done
        return Request {
            // The last one waiting stops the download.
            if (job.callbacks.remove(done) && job.callbacks.isEmpty() && preloading[key] === job) {
                preloading.remove(key)
                job.cancelled = true
                job.writer?.cancel()
            }
        }
    }

    private fun write(job: Preload, key: String, url: String) {
        val ok = if (job.cancelled) {
            false
        } else {
            val writer = CacheWriter(cached.createDataSource(), DataSpec(Uri.parse(url)), null, null)
            job.writer = writer
            try {
                if (!job.cancelled) writer.cache()
                !job.cancelled
            } catch (e: Exception) {
                // The file came, but the cache could not keep it: it can still be read.
                !job.cancelled && isCacheFailure(e)
            }
        }
        main.post {
            if (preloading[key] !== job) return@post
            preloading.remove(key)
            job.callbacks.toList().forEach { it(ok) }
        }
    }

    /**
     * Reads a lone clip's length and whether it has a sound track from its
     * metadata, off the main thread; [done] runs on the main thread, with null
     * when it cannot be read.
     */
    fun clipFile(url: String, done: (ClipFile?) -> Unit): Request {
        val waiting = AtomicReference(done)
        work.execute {
            if (waiting.get() == null) return@execute
            val file = readClipFile(url)
            main.post { waiting.getAndSet(null)?.invoke(file) }
        }
        return Request { waiting.set(null) }
    }

    private fun readClipFile(url: String): ClipFile? {
        val retriever = MediaMetadataRetriever()
        return try {
            if (isRemote(url)) retriever.setDataSource(url, emptyMap()) else retriever.setDataSource(context, Uri.parse(url))
            val ms = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
            val voiced = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO) == "yes"
            ms?.takeIf { it > 0 }?.let { ClipFile(it / 1000.0, voiced) }
        } catch (_: Exception) {
            null
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
                // Released either way.
            }
        }
    }

    /** Loads a still image; [done] runs on the main thread with null when it cannot load. */
    fun image(url: String, done: (Bitmap?) -> Unit): Request {
        val key = fileKey(url)
        stills.get(key)?.let { bitmap ->
            val task = Runnable { done(bitmap) }
            main.post(task)
            return Request { main.removeCallbacks(task) }
        }
        val waiting = AtomicReference(done)
        val task = work.submit(Runnable {
            if (waiting.get() == null) return@Runnable
            val bitmap = try {
                val source: DataSource = if (isRemote(url)) cached.createDataSource() else local.createDataSource()
                try {
                    source.open(DataSpec(Uri.parse(url)))
                    val bytes = DataSourceUtil.readToEnd(source)
                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                } finally {
                    source.close()
                }
            } catch (_: Exception) {
                null
            }
            main.post {
                if (bitmap != null) stills.put(key, bitmap)
                waiting.getAndSet(null)?.invoke(bitmap)
            }
        })
        return Request {
            waiting.set(null)
            task.cancel(false)
        }
    }

    companion object {
        private const val CACHE_BYTES = 200L * 1024 * 1024
        @Volatile private var shared: MediaFiles? = null

        fun get(context: Context): MediaFiles =
            shared ?: synchronized(this) { shared ?: MediaFiles(context.applicationContext).also { shared = it } }

        private fun isRemote(url: String) = url.startsWith("http://") || url.startsWith("https://")

        private fun processName(): String? =
            if (Build.VERSION.SDK_INT >= 28) {
                Application.getProcessName()
            } else {
                try {
                    File("/proc/self/cmdline").readBytes().takeWhile { it != 0.toByte() }.toByteArray().decodeToString()
                } catch (_: IOException) {
                    null
                }
            }
    }
}

/**
 * The cache folder of a process: its name made safe for a file name. Two
 * processes of one app never share a SimpleCache folder, which would corrupt it.
 */
internal fun processFolder(processName: String?, packageName: String): String =
    (processName?.trim()?.takeIf { it.isNotEmpty() } ?: packageName).replace(Regex("[^A-Za-z0-9._-]"), "_")

/** Whether [e] came from the disk cache (a full disk, say), not from the file. */
@OptIn(UnstableApi::class)
internal fun isCacheFailure(e: Throwable): Boolean =
    generateSequence(e) { it.cause }.take(8).any { it is Cache.CacheException || it is CacheDataSink.CacheDataSinkException }

/**
 * Writes to the disk cache when it can. A write that fails (a full disk) stops
 * caching for that read instead of failing it: the file still plays from the
 * network, and the slot keeps the clip in memory for its loops.
 */
@OptIn(UnstableApi::class)
internal fun tolerantCacheSink(cache: Cache): DataSink.Factory {
    val sinks = CacheDataSink.Factory().setCache(cache)
    return DataSink.Factory { TolerantSink(sinks.createDataSink()) }
}

@OptIn(UnstableApi::class)
private class TolerantSink(private val sink: DataSink) : DataSink {
    /** The cache failed during this read; nothing more is written until the next open. */
    private var failed = false

    override fun open(dataSpec: DataSpec) {
        failed = false
        try {
            sink.open(dataSpec)
        } catch (_: IOException) {
            failed = true
        }
    }

    override fun write(buffer: ByteArray, offset: Int, length: Int) {
        if (failed) return
        try {
            sink.write(buffer, offset, length)
        } catch (_: IOException) {
            failed = true
            // Keeps what was written, or drops the file it could not finish.
            try {
                sink.close()
            } catch (_: IOException) {
            }
        }
    }

    override fun close() {
        if (failed) return
        try {
            sink.close()
        } catch (_: IOException) {
        }
    }
}
