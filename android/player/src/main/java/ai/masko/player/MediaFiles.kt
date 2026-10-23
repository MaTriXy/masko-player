package ai.masko.player

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.LruCache
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSourceUtil
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.CacheWriter
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import java.io.File
import java.util.concurrent.Executors

/**
 * Clip, still and sound files, one per process: remote files go through a
 * disk cache keyed by the link without its query, so a refreshed signed link
 * still finds the file cached.
 */
@OptIn(UnstableApi::class)
internal class MediaFiles private constructor(context: Context) {
    private val cache = SimpleCache(
        File(context.cacheDir, "masko-player"),
        LeastRecentlyUsedCacheEvictor(CACHE_BYTES),
        StandaloneDatabaseProvider(context),
    )
    private val http = DefaultHttpDataSource.Factory().setAllowCrossProtocolRedirects(true)
    private val cached = CacheDataSource.Factory()
        .setCache(cache)
        .setUpstreamDataSourceFactory(http)
        .setCacheKeyFactory { spec -> fileKey(spec.uri.toString()) }
        .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
    private val local = DefaultDataSource.Factory(context, http)
    private val remoteSources = ProgressiveMediaSource.Factory(cached)
    private val localSources = ProgressiveMediaSource.Factory(local)
    private val work = Executors.newFixedThreadPool(2) { r -> Thread(r, "MaskoMediaFiles").apply { isDaemon = true } }
    private val main = Handler(Looper.getMainLooper())
    private val stills = LruCache<String, Bitmap>(8)
    private val preloading = HashMap<String, MutableList<(Boolean) -> Unit>>()

    fun source(url: String): MediaSource =
        (if (isRemote(url)) remoteSources else localSources).createMediaSource(MediaItem.fromUri(url))

    /** Puts a remote file in the cache; [done] runs on the main thread. Local files are there already. */
    fun preload(url: String, done: (Boolean) -> Unit) {
        if (!isRemote(url)) {
            main.post { done(true) }
            return
        }
        val key = fileKey(url)
        preloading[key]?.let {
            it += done
            return
        }
        preloading[key] = mutableListOf(done)
        work.execute {
            val ok = try {
                CacheWriter(cached.createDataSource(), DataSpec(Uri.parse(url)), null, null).cache()
                true
            } catch (_: Exception) {
                false
            }
            main.post { preloading.remove(key)?.forEach { it(ok) } }
        }
    }

    /** Loads a still image; [done] runs on the main thread with null when it cannot load. */
    fun image(url: String, done: (Bitmap?) -> Unit) {
        val key = fileKey(url)
        stills.get(key)?.let {
            main.post { done(it) }
            return
        }
        work.execute {
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
                done(bitmap)
            }
        }
    }

    companion object {
        private const val CACHE_BYTES = 200L * 1024 * 1024
        @Volatile private var shared: MediaFiles? = null

        fun get(context: Context): MediaFiles =
            shared ?: synchronized(this) { shared ?: MediaFiles(context.applicationContext).also { shared = it } }

        private fun isRemote(url: String) = url.startsWith("http://") || url.startsWith("https://")
    }
}
