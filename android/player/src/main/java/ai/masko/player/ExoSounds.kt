package ai.masko.player

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer

/** Edge sounds, one ExoPlayer each, freed when a one-shot sound ends (rules.md 9.6). */
@OptIn(UnstableApi::class)
internal class ExoSounds(context: Context, private val media: MediaFiles) : Sounds {
    private class Playing(val player: ExoPlayer, val url: String, val volume: Float, val loop: Boolean)

    private val context = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val playing = ArrayList<Playing>()
    /** Looping sounds freed by [detach], played again at the next [resume]. */
    private val detachedLoops = ArrayList<Pair<String, Float>>()
    private var paused = false

    override fun play(url: String, volume: Float, loop: Boolean) {
        val player = ExoPlayer.Builder(context).build()
        val entry = Playing(player, url, volume, loop)
        val attributes = AudioAttributes.Builder()
            .setUsage(C.USAGE_MEDIA)
            .setContentType(C.AUDIO_CONTENT_TYPE_SONIFICATION)
            .build()
        player.setAudioAttributes(attributes, false)
        player.volume = volume
        player.repeatMode = if (loop) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
        player.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                if (state == Player.STATE_ENDED) finish(entry)
            }

            override fun onPlayerError(error: PlaybackException) = finish(entry)
        })
        player.setMediaSource(media.source(url))
        player.playWhenReady = !paused
        player.prepare()
        playing += entry
    }

    // Released after the callback that reported the end has returned.
    private fun finish(entry: Playing) {
        main.post {
            if (playing.remove(entry)) entry.player.release()
        }
    }

    override fun stop(onlyLooping: Boolean) {
        val stopped = playing.filter { !onlyLooping || it.loop }
        playing.removeAll(stopped.toSet())
        stopped.forEach { it.player.release() }
        detachedLoops.clear()
    }

    override fun pause() {
        paused = true
        playing.forEach { it.player.playWhenReady = false }
    }

    override fun resume() {
        paused = false
        val loops = detachedLoops.toList()
        detachedLoops.clear()
        loops.forEach { (url, volume) -> play(url, volume, loop = true) }
        playing.forEach { it.player.playWhenReady = true }
    }

    override fun detach() {
        playing.filter { it.loop }.forEach { detachedLoops += it.url to it.volume }
        playing.forEach { it.player.release() }
        playing.clear()
    }

    override fun release() = stop(onlyLooping = false)
}
