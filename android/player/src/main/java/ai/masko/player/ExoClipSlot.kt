package ai.masko.player

import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.LoadControl

/**
 * One persistent video slot: a Media3 ExoPlayer drawing stacked clips into its
 * own [StackedVideoView].
 *
 * A load sets the clip, then a fresh output, so the first frame drawn on that
 * output is the new clip's. [ClipSlot.Events.onFirstFrame] waits for both
 * Media3's `onRenderedFirstFrame` and that frame being drawn in the view.
 *
 * The decoder exists only while the view can draw: it is made when a clip
 * loads into a view with a surface, freed when the surface goes (the view left
 * its window), and made again when the surface is back, on the same clip at
 * the same frame.
 */
@OptIn(UnstableApi::class)
internal class ExoClipSlot(
    context: Context,
    private val view: StackedVideoView,
    private val media: MediaFiles,
    private val onHostChanged: () -> Unit,
) : ClipSlot, StackedVideoView.Listener, Player.Listener {

    override var events: ClipSlot.Events? = null

    private val context = context.applicationContext
    private var player: ExoPlayer? = null

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

    // What the slot was told, kept for a decoder made again.
    private var playing = false
    private var rate = 1f
    private var volume = 0f
    /** The clip time while there is no decoder, in milliseconds. */
    private var heldMs = 0L

    /** For instrumented tests: what happened, in order. */
    internal var trace: ((String) -> Unit)? = null

    /** For instrumented tests: whether the slot has a decoder now. */
    internal val hasDecoder get() = player != null

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
        playing = false
        heldMs = 0
        player?.playWhenReady = false
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
        val made = player == null
        val p = player ?: makePlayer().also { player = it }
        if (!sourceSet) {
            // The clip first, then the output: no frame of an earlier clip can reach it.
            p.setMediaSource(media.source(clip))
            p.prepare()
            sourceSet = true
        } else if (made) {
            // The surface is back: the same clip, at the frame it was on.
            p.setMediaSource(media.source(clip))
            p.prepare()
            p.seekTo(heldMs)
            p.setPlaybackSpeed(rate)
            p.playWhenReady = playing
            trace?.invoke("restored")
        }
        // Blocks until the decoder has let go of the previous output.
        p.setVideoSurface(out.surface)
        output?.let(view::release)
        output = out
        loadOutput = out.id
        // A new output of the same decoder: draw the paused frame again.
        if (sourceSet && !made && !playing) p.seekTo(p.currentPosition)
    }

    private fun makePlayer(): ExoPlayer =
        ExoPlayer.Builder(context)
            .setLoadControl(clipLoadControl())
            .build()
            .also {
                it.addListener(this)
                it.playWhenReady = false
                it.volume = volume
                // A mascot never takes audio focus from the app.
                it.setAudioAttributes(AudioAttributes.DEFAULT, false)
            }

    override fun play(rate: Double) {
        this.rate = rate.toFloat()
        playing = true
        player?.let {
            it.setPlaybackSpeed(this.rate)
            it.playWhenReady = true
        }
    }

    override fun rewind() {
        heldMs = 0
        player?.seekTo(0)
    }

    override fun pause() {
        playing = false
        player?.playWhenReady = false
    }

    override fun setVisible(visible: Boolean) {
        view.alpha = if (visible) 1f else 0f
        trace?.invoke(if (visible) "visible" else "hidden")
    }

    override fun setVolume(volume: Float) {
        this.volume = volume
        player?.volume = volume
    }

    override fun position(): Double = (player?.currentPosition ?: heldMs) / 1000.0

    override fun release() {
        if (released) return
        released = true
        if (view.listener === this) view.listener = null
        player?.release()
        player = null
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
        onHostChanged.invoke()
        request()
    }

    override fun onHostFailed(detail: String) {
        onHostChanged.invoke()
    }

    override fun onHostLost() {
        // The outputs are freed next: the decoder goes first, and is made again with the next surface.
        player?.let {
            heldMs = it.currentPosition
            it.release()
            trace?.invoke("decoderFreed")
        }
        player = null
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
        // Until the new clip is in the player, an error is the earlier clip's, which the slot has let go.
        if (url == null || !sourceSet) return
        trace?.invoke("failed")
        events?.onFailed(error.errorCodeName)
    }

    override fun onVideoSizeChanged(videoSize: VideoSize) {
        if (sourceSet) view.setVideoSize(videoSize.width, videoSize.height)
    }
}

/**
 * Keeps up to a minute of played video in memory, so a loop seeks back inside
 * the clip instead of reading the file again (from the network, when the disk
 * cache could not keep it).
 */
@OptIn(UnstableApi::class)
internal fun clipLoadControl(): LoadControl =
    DefaultLoadControl.Builder()
        .setBackBuffer(60_000, true)
        .build()
