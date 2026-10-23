package ai.masko.player

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.View
import android.widget.FrameLayout
import android.widget.ImageView
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import kotlin.math.max

/**
 * Shows a Masko mascot. Load a release delivery with [load]; taps and the
 * pointer reach the canvas as `action::click` and `behavior::pointerHover`.
 *
 * The mascot is drawn transparent and fitted inside the view, centred. While
 * the view is off screen (detached, or its window hidden) the player pauses
 * itself and resumes when it is back.
 */
class MaskoPlayerView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0,
) : FrameLayout(context, attrs, defStyleAttr) {

    /** The two video slots, stacked; the hidden one has alpha 0 so its surface stays alive. */
    internal val videos = arrayOf(StackedVideoView(context), StackedVideoView(context))
    internal val still = ImageView(context).apply {
        scaleType = ImageView.ScaleType.FIT_CENTER
        visibility = View.GONE
    }

    /** The player of the last [load], until it is destroyed. */
    var player: MaskoPlayer? = null
        private set

    /** The slots of the last [load], for instrumented tests. */
    internal var stage: ViewStage? = null
        private set

    init {
        for (video in videos) {
            video.alpha = 0f
            addView(video, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        }
        addView(still, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        isClickable = true
        setOnClickListener { player?.click() }
    }

    /**
     * Plays this release delivery (the `delivery` object of
     * `GET /v1/canvases/{canvasId}/releases/{releaseId}/delivery`, as JSON).
     * A player loaded before is destroyed.
     */
    @JvmOverloads
    fun load(delivery: String, options: MaskoPlayer.Options = MaskoPlayer.Options()): MaskoPlayer {
        player?.destroy()
        val media = MediaFiles.get(context)
        val stage = ViewStage(this, media).also { this.stage = it }
        val next = MaskoPlayer(
            delivery,
            stage,
            ExoSounds(context, media),
            HandlerScheduler(),
            SystemClock::elapsedRealtime,
            System::currentTimeMillis,
            options,
        )
        player = next
        next.setHostActive(onScreen())
        return next
    }

    override fun onHoverEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_HOVER_ENTER -> player?.hover(true)
            MotionEvent.ACTION_HOVER_EXIT -> player?.hover(false)
        }
        return super.onHoverEvent(event)
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        player?.setHostActive(onScreen())
    }

    override fun onDetachedFromWindow() {
        player?.setHostActive(false)
        super.onDetachedFromWindow()
    }

    override fun onWindowVisibilityChanged(visibility: Int) {
        super.onWindowVisibilityChanged(visibility)
        player?.setHostActive(onScreen())
    }

    private fun onScreen() = isAttachedToWindow && windowVisibility == View.VISIBLE
}

/** The view side of [MaskoPlayer]: two [ExoClipSlot]s, the still image and the cache. */
@OptIn(UnstableApi::class)
internal class ViewStage(private val view: MaskoPlayerView, private val media: MediaFiles) : Stage {
    override val slots: List<ExoClipSlot> = view.videos.map { ExoClipSlot(view.context, it, media, ::hostChanged) }
    private var ready: (() -> Unit)? = null
    private var stillLoad = 0

    override fun whenReady(ready: () -> Unit) {
        this.ready = ready
        hostChanged()
    }

    private fun hostChanged() {
        val r = ready ?: return
        if (view.videos.all { it.hasHost }) {
            ready = null
            r()
        }
    }

    override fun sizePx(): Int = max(view.width, view.height)

    override fun showStill(url: String?, shown: () -> Unit) {
        val load = ++stillLoad
        if (url == null) {
            view.still.setImageDrawable(null)
            view.still.visibility = View.GONE
            shown()
            return
        }
        media.image(url) { bitmap ->
            if (load != stillLoad) return@image
            view.still.setImageBitmap(bitmap)
            view.still.visibility = if (bitmap != null) View.VISIBLE else View.GONE
            shown()
        }
    }

    override fun cancelStill() {
        stillLoad++
    }

    override fun hideStill() {
        stillLoad++
        view.still.visibility = View.GONE
        view.still.setImageDrawable(null)
    }

    override fun preload(url: String, done: (Boolean) -> Unit) = media.preload(url, done)

    override fun release() {
        stillLoad++
        slots.forEach { it.release() }
    }
}

/** Runs tasks on the main thread. */
internal class HandlerScheduler(private val handler: Handler = Handler(Looper.getMainLooper())) : Scheduler {
    override fun post(task: Runnable) {
        handler.post(task)
    }

    override fun postDelayed(task: Runnable, delayMs: Long) {
        handler.postDelayed(task, delayMs)
    }

    override fun cancel(task: Runnable) {
        handler.removeCallbacks(task)
    }
}
