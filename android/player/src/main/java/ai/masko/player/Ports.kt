package ai.masko.player

/**
 * What [MaskoPlayer] drives. The Android classes ([MaskoPlayerView], [ExoClipSlot],
 * [ExoSounds], [HandlerScheduler]) implement these; JVM tests use fakes. Every
 * call and callback happens on the main thread.
 */

/** One persistent video slot: a decoder drawing stacked clips into its own view. */
internal interface ClipSlot {
    var events: Events?

    /**
     * Loads [url] paused on its first frame, then reports [Events.onFirstFrame]
     * once that frame is drawn in the slot's view. Events of an earlier load are
     * never reported after this call.
     */
    fun load(url: String)

    /** Plays from the frame on screen, at [rate]. */
    fun play(rate: Double)

    /** Goes back to the first frame, keeping play or pause. */
    fun rewind()

    fun pause()

    /** Shows or hides the slot's view. Two calls in one main-thread turn land in one frame. */
    fun setVisible(visible: Boolean)

    fun setVolume(volume: Float)

    /** Clip time on screen, in seconds. */
    fun position(): Double

    fun release()

    interface Events {
        fun onFirstFrame()
        fun onEnded()
        fun onFailed(message: String)
    }
}

/** The view around the slots: the still image, the size and the clip cache. */
internal interface Stage {
    val slots: List<ClipSlot>

    /**
     * Calls [ready] once clips can be drawn (the view is laid out and has
     * surfaces). Calls [failed] at most once, with what is wrong, when the view
     * cannot get a surface; [ready] may still follow when it gets one later.
     */
    fun whenReady(ready: () -> Unit, failed: (detail: String) -> Unit)

    /** The mascot's size on screen in pixels (its longer side, density included), 0 when unknown. */
    fun sizePx(): Int

    /**
     * Loads the still at [url] (or nothing when null), puts it on screen above
     * the video, then calls [shown]. A later [cancelStill], [hideStill] or
     * [showStill] cancels a still not yet shown.
     */
    fun showStill(url: String?, shown: () -> Unit)

    /** Cancels a still that is loading; a still on screen stays. */
    fun cancelStill()

    /** Takes the still off screen. */
    fun hideStill()

    /**
     * Loads [url] into the clip cache, then calls [done] with whether the file
     * can be read. A file that loads but cannot be cached (a full disk) can.
     */
    fun preload(url: String, done: (Boolean) -> Unit)

    /** Reads a video's length in seconds from its metadata, then calls [done], with null when it cannot be read. */
    fun clipLength(url: String, done: (Double?) -> Unit)

    /** Frees the slots and cancels preloads and still loads; nothing is called back afterwards. */
    fun release()
}

/** Edge sounds (rules.md 9.6). */
internal interface Sounds {
    fun play(url: String, volume: Float, loop: Boolean)

    /** Stops looping sounds, or every sound. */
    fun stop(onlyLooping: Boolean)

    /** Pauses every sound; sounds played while paused wait for [resume]. */
    fun pause()

    fun resume()

    /**
     * The view left its window: frees every sound's decoder. Looping sounds
     * play again at the next [resume]; one-shot sounds are dropped.
     */
    fun detach()

    fun release()
}

/** The main thread's message queue. [post] may be called from any thread. */
internal interface Scheduler {
    fun post(task: Runnable)
    fun postDelayed(task: Runnable, delayMs: Long)
    fun cancel(task: Runnable)

    /** Whether the caller runs on the main thread. */
    fun isMainThread(): Boolean
}
