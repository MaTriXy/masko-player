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

/**
 * Shows a Masko mascot. Load a release delivery with [load], or one
 * animation's file with [loadClip]; taps and the pointer reach the canvas as
 * `action::click` and `behavior::pointerHover`.
 *
 * The mascot is drawn transparent and fitted inside the view, centred. While
 * the view is off screen (detached, GONE or INVISIBLE, itself or a parent, or
 * its window hidden) the player pauses itself and resumes when it is back.
 * Detached, it also frees its video decoders, and loads the clip again at the
 * same frame when it is attached again. Call [MaskoPlayer.destroy] when you
 * are done with the mascot. The view needs a hardware-accelerated window.
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

    /** Whether this view and every parent are visible (onVisibilityAggregated). */
    private var shown = false

    /** Reports a view that never gets a surface (no hardware acceleration, no size). */
    private val surfaceCheck = Runnable { checkSurface() }

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
     * A player loaded before is destroyed. Main thread only.
     */
    @JvmOverloads
    fun load(delivery: String, options: MaskoPlayer.Options = MaskoPlayer.Options()): MaskoPlayer =
        start("load", delivery, null, options)

    /**
     * Plays one animation on its own, looped: its stacked MP4 file (colour
     * above, transparency below). The player reads the file's length first;
     * a file it cannot read plays nothing and reports `clip_failed`. A player
     * loaded before is destroyed. Main thread only.
     */
    @JvmOverloads
    fun loadClip(stacked: String, options: MaskoPlayer.Options = MaskoPlayer.Options()): MaskoPlayer =
        start("loadClip", "", stacked, options)

    private fun start(method: String, delivery: String, clip: String?, options: MaskoPlayer.Options): MaskoPlayer {
        check(Looper.myLooper() == Looper.getMainLooper()) {
            "MaskoPlayerView.$method must be called on the main thread, not on thread \"${Thread.currentThread().name}\""
        }
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
            clip = clip,
        )
        player = next
        next.setHostAttached(isAttachedToWindow)
        hostChanged()
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
        player?.setHostAttached(true)
        hostChanged()
    }

    override fun onDetachedFromWindow() {
        removeCallbacks(surfaceCheck)
        player?.setHostActive(false)
        player?.setHostAttached(false)
        super.onDetachedFromWindow()
    }

    override fun onWindowVisibilityChanged(visibility: Int) {
        super.onWindowVisibilityChanged(visibility)
        hostChanged()
    }

    override fun onVisibilityAggregated(isVisible: Boolean) {
        super.onVisibilityAggregated(isVisible)
        shown = isVisible
        hostChanged()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        hostChanged()
    }

    private fun onScreen() = shown && isAttachedToWindow && windowVisibility == View.VISIBLE

    private fun hostChanged() {
        val active = onScreen()
        player?.setHostActive(active)
        removeCallbacks(surfaceCheck)
        if (active && stage?.isReady == false) postDelayed(surfaceCheck, SURFACE_WAIT_MS)
    }

    private fun checkSurface() {
        val stage = stage ?: return
        if (!onScreen() || stage.isReady) return
        stage.surfaceMissing(
            when {
                !isHardwareAccelerated -> "the window is not hardware accelerated, which the video needs"
                width == 0 || height == 0 -> "the view is $width x $height pixels"
                else -> "the video got no surface; is a parent drawn in a software layer?"
            }
        )
    }

    private companion object {
        /** On screen this long without a surface, the view reports `surface_unavailable`. */
        const val SURFACE_WAIT_MS = 2_000L
    }
}

/** The view side of [MaskoPlayer]: two [ExoClipSlot]s, the still image and the cache. */
@OptIn(UnstableApi::class)
internal class ViewStage(private val view: MaskoPlayerView, private val media: MediaFiles) : Stage {
    override val slots: List<ExoClipSlot> = view.videos.map { ExoClipSlot(view.context, it, media, ::hostChanged) }
    private var ready: (() -> Unit)? = null
    private var failed: ((String) -> Unit)? = null
    private var still: MediaFiles.Request? = null
    private val preloads = HashSet<MediaFiles.Request>()
    private var released = false

    /** Whether both slots can draw. */
    val isReady get() = view.videos.all { it.hasHost }

    /** Preloads and still loads not done yet, for instrumented tests. */
    internal val pending get() = preloads.size + (if (still != null) 1 else 0)

    override fun whenReady(ready: () -> Unit, failed: (detail: String) -> Unit) {
        this.ready = ready
        this.failed = failed
        hostChanged()
    }

    private fun hostChanged() {
        view.videos.firstNotNullOfOrNull { it.failure }?.let(::surfaceMissing)
        val r = ready ?: return
        if (isReady) {
            ready = null
            r()
        }
    }

    /** The view cannot get a surface: reported once. */
    fun surfaceMissing(detail: String) {
        val f = failed ?: return
        failed = null
        f(detail)
    }

    override fun sizePx(): Int =
        fittedSizePx(view.width, view.height, view.videos.firstNotNullOfOrNull { it.mascotAspect })

    override fun showStill(url: String?, shown: () -> Unit) {
        cancelStill()
        if (url == null) {
            view.still.setImageDrawable(null)
            view.still.visibility = View.GONE
            shown()
            return
        }
        still = media.image(url) { bitmap ->
            still = null
            view.still.setImageBitmap(bitmap)
            view.still.visibility = if (bitmap != null) View.VISIBLE else View.GONE
            shown()
        }
    }

    override fun cancelStill() {
        still?.cancel()
        still = null
    }

    override fun hideStill() {
        cancelStill()
        view.still.visibility = View.GONE
        view.still.setImageDrawable(null)
    }

    override fun preload(url: String, done: (Boolean) -> Unit) {
        if (released) return
        lateinit var request: MediaFiles.Request
        request = media.preload(url) { ok ->
            preloads.remove(request)
            done(ok)
        }
        preloads += request
    }

    override fun clipFile(url: String, done: (ClipFile?) -> Unit) {
        if (released) return
        lateinit var request: MediaFiles.Request
        request = media.clipFile(url) { file ->
            preloads.remove(request)
            done(file)
        }
        preloads += request
    }

    override fun release() {
        if (released) return
        released = true
        ready = null
        failed = null
        cancelStill()
        preloads.toList().forEach { it.cancel() }
        preloads.clear()
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

    override fun isMainThread(): Boolean = Looper.myLooper() === handler.looper
}
