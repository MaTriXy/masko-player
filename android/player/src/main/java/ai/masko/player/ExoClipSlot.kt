package ai.masko.player

import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer

/**
 * One persistent video slot: a Media3 ExoPlayer drawing stacked clips into its
 * own [StackedVideoView].
 *
 * A load sets the clip, then a fresh output, so the first frame drawn on that
 * output is the new clip's. [ClipSlot.Events.onFirstFrame] waits for both
 * Media3's `onRenderedFirstFrame` and that frame being drawn in the view.
 */
@OptIn(UnstableApi::class)
internal class ExoClipSlot(
    context: Context,
    private val view: StackedVideoView,
    private val media: MediaFiles,
    private val onHostReady: () -> Unit,
) : ClipSlot, StackedVideoView.Listener, Player.Listener {

    override var events: ClipSlot.Events? = null

    private val player: ExoPlayer = ExoPlayer.Builder(context).build().also {
        it.addListener(this)
        it.playWhenReady = false
        it.volume = 0f
        // A mascot never takes audio focus from the app.
        it.setAudioAttributes(AudioAttributes.DEFAULT, false)
    }

    private var url: String? = null
    /** The clip's media is in the player (it waits for an output first). */
    private var sourceSet = false
    private var requesting = false
    private var output: StackedVideoView.Output? = null
    /** The output frames of the current load are drawn into; -1 before it has one. */
    private var loadOutput = -1
    private var renderedFirst = false
    private var drawn = false
    private var ready = false
    private var released = false

    /** For instrumented tests: what happened, in order. */
    internal var trace: ((String) -> Unit)? = null

    init {
        view.listener = this
    }

    override fun load(url: String) {
        this.url = url
        sourceSet = false
        loadOutput = -1
        renderedFirst = false
        drawn = false
        ready = false
        player.playWhenReady = false
        trace?.invoke("load")
        request()
    }

    private fun request() {
        if (released || requesting || url == null || !view.hasHost) return
        requesting = true
        view.createOutput { out ->
            requesting = false
            attach(out)
        }
    }

    private fun attach(out: StackedVideoView.Output) {
        val clip = url
        if (released || clip == null || !view.hasHost) {
            view.release(out)
            return
        }
        val reattach = sourceSet
        if (!sourceSet) {
            // The clip first, then the output: no frame of an earlier clip can reach it.
            player.setMediaSource(media.source(clip))
            player.prepare()
            sourceSet = true
        }
        // Blocks until the decoder has let go of the previous output.
        player.setVideoSurface(out.surface)
        output?.let(view::release)
        output = out
        loadOutput = out.id
        // After a lost surface, draw the paused frame again.
        if (reattach && !player.playWhenReady) player.seekTo(player.currentPosition)
    }

    override fun play(rate: Double) {
        player.setPlaybackSpeed(rate.toFloat())
        player.playWhenReady = true
    }

    override fun rewind() {
        player.seekTo(0)
    }

    override fun pause() {
        player.playWhenReady = false
    }

    override fun setVisible(visible: Boolean) {
        view.alpha = if (visible) 1f else 0f
        trace?.invoke(if (visible) "visible" else "hidden")
    }

    override fun setVolume(volume: Float) {
        player.volume = volume
    }

    override fun position(): Double = player.currentPosition / 1000.0

    override fun release() {
        if (released) return
        released = true
        if (view.listener === this) view.listener = null
        player.release()
        output?.let(view::release)
        output = null
    }

    private fun checkReady() {
        if (ready || !renderedFirst || !drawn) return
        ready = true
        trace?.invoke("firstFrame")
        events?.onFirstFrame()
    }

    // ------------------------------------------------------------------ the view

    override fun onHostReady() {
        onHostReady.invoke()
        request()
    }

    override fun onHostLost() {
        // The outputs are freed next; the decoder lets go of them first.
        player.clearVideoSurface()
        output = null
        loadOutput = -1
        requesting = false
    }

    override fun onFrameDrawn(output: Int) {
        if (output != loadOutput || drawn) return
        drawn = true
        trace?.invoke("drawn")
        checkReady()
    }

    // ------------------------------------------------------------------ the player

    override fun onRenderedFirstFrame() {
        if (!sourceSet || renderedFirst) return
        renderedFirst = true
        trace?.invoke("renderedFirstFrame")
        checkReady()
    }

    override fun onPlaybackStateChanged(state: Int) {
        if (state == Player.STATE_ENDED && sourceSet && ready) {
            trace?.invoke("ended")
            events?.onEnded()
        }
    }

    override fun onPlayerError(error: PlaybackException) {
        if (url == null) return
        trace?.invoke("failed")
        events?.onFailed(error.errorCodeName)
    }

    override fun onVideoSizeChanged(videoSize: VideoSize) {
        view.setVideoSize(videoSize.width, videoSize.height)
    }
}
