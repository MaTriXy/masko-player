package ai.masko.player

import org.json.JSONObject

/** A file's name in a link, for short logs: `https://cdn.test/a/loop.mp4?sig=1` is `loop.mp4`. */
internal fun short(url: String?): String = url?.substringBefore('?')?.substringAfterLast('/') ?: "-"

/** Fake time: milliseconds since the test started. */
internal class FakeTime {
    var now = 0L
}

/** The main thread's queue, run by hand. */
internal class FakeScheduler(private val time: FakeTime) : Scheduler {
    private class Task(val at: Long, val order: Long, val task: Runnable)

    private val tasks = ArrayList<Task>()
    private var order = 0L

    override fun post(task: Runnable) = postDelayed(task, 0)

    override fun postDelayed(task: Runnable, delayMs: Long) {
        tasks += Task(time.now + delayMs, order++, task)
    }

    override fun cancel(task: Runnable) {
        tasks.removeAll { it.task === task }
    }

    /** When [task] is due, or null when it is not queued. */
    fun dueAt(task: Runnable? = null): List<Long> = tasks.filter { task == null || it.task === task }.map { it.at }

    /** Moves time on by [ms], running every task at its time, in order. */
    fun advance(ms: Long) {
        val until = time.now + ms
        while (true) {
            val next = tasks.filter { it.at <= until }.minWithOrNull(compareBy<Task>({ it.at }, { it.order })) ?: break
            tasks.remove(next)
            time.now = maxOf(time.now, next.at)
            next.task.run()
        }
        time.now = until
    }

    /** Runs what is due now. */
    fun turn() = advance(0)
}

/** A video slot that does what the test says, when it says. */
internal class FakeSlot(private val index: Int, private val log: MutableList<String>) : ClipSlot {
    override var events: ClipSlot.Events? = null
    var url: String? = null
    /** On screen (setVisible). */
    var shown = false
    var playing = false
    var rate = 0.0
    /** The clip's voice volume (setVolume). */
    var level = 0f
    var time = 0.0
    var released = false
    val loads = ArrayList<String>()

    override fun load(url: String) {
        this.url = url
        playing = false
        time = 0.0
        loads += url
        log += "$index load ${short(url)}"
    }

    override fun play(rate: Double) {
        playing = true
        this.rate = rate
        log += "$index play $rate"
    }

    override fun rewind() {
        time = 0.0
        log += "$index rewind"
    }

    override fun pause() {
        if (playing) log += "$index pause"
        playing = false
    }

    override fun setVisible(visible: Boolean) {
        if (shown != visible) log += "$index ${if (visible) "show" else "hide"}"
        shown = visible
    }

    override fun setVolume(volume: Float) {
        level = volume
    }

    override fun position() = time

    override fun release() {
        released = true
    }

    /** The loaded clip's first frame is drawn. */
    fun firstFrame() = events!!.onFirstFrame()

    /** The clip reached its end. */
    fun end() = events!!.onEnded()

    /** The clip cannot load or decode. */
    fun fail() = events!!.onFailed("fake")
}

internal class FakeStage(private val log: MutableList<String>) : Stage {
    override val slots = listOf(FakeSlot(0, log), FakeSlot(1, log))
    var size = 300
    var ready = true
    private var waiting: (() -> Unit)? = null
    var still: String? = null
    private var loadingStill: Pair<String?, () -> Unit>? = null
    val preloads = ArrayList<Pair<String, (Boolean) -> Unit>>()
    var released = false

    override fun whenReady(ready: () -> Unit) {
        if (this.ready) ready() else waiting = ready
    }

    fun becomeReady() {
        ready = true
        waiting?.invoke()
        waiting = null
    }

    override fun sizePx() = size

    override fun showStill(url: String?, shown: () -> Unit) {
        loadingStill = url to shown
        log += "still load ${short(url)}"
    }

    /** The still asked for has loaded. */
    fun stillLoaded() {
        val (url, shown) = loadingStill!!
        loadingStill = null
        still = url
        log += "still show ${short(url)}"
        shown()
    }

    val stillLoading get() = loadingStill != null

    override fun cancelStill() {
        loadingStill = null
    }

    override fun hideStill() {
        loadingStill = null
        if (still != null) log += "still hide"
        still = null
    }

    override fun preload(url: String, done: (Boolean) -> Unit) {
        preloads += url to done
        log += "preload ${short(url)}"
    }

    override fun release() {
        released = true
        slots.forEach { it.release() }
    }
}

internal class FakeSounds(private val log: MutableList<String>) : Sounds {
    val playing = ArrayList<Pair<String, Boolean>>()
    var paused = false
    var released = false

    override fun play(url: String, volume: Float, loop: Boolean) {
        playing += short(url) to loop
        log += "sound ${short(url)} $volume ${if (loop) "loop" else "once"}"
    }

    override fun stop(onlyLooping: Boolean) {
        playing.removeAll { !onlyLooping || it.second }
        log += "sounds stop ${if (onlyLooping) "looping" else "all"}"
    }

    override fun pause() {
        paused = true
        log += "sounds pause"
    }

    override fun resume() {
        paused = false
        log += "sounds resume"
    }

    override fun release() {
        released = true
        playing.clear()
    }
}

/** Everything the app hears, as `pose:idle`, `clip:loop-idle`, `done:action::boop:used`, ... */
internal class Heard : MaskoPlayer.Listener {
    val events = ArrayList<String>()
    /** Each clip event in full: `loop-idle POSE 1.0`. */
    val clips = ArrayList<String>()
    val movements = ArrayList<Pair<String, JSONObject>>()
    /** Each movement's rate and seconds. */
    val timings = ArrayList<Pair<Double, Double>>()
    val details = ArrayList<String?>()

    override fun onPose(pose: String) {
        events += "pose:$pose"
    }

    override fun onClip(clip: String, kind: MaskoPlayer.ClipKind, rate: Double) {
        events += "clip:$clip"
        clips += "$clip $kind $rate"
    }

    override fun onReactionDone(name: String, used: Boolean) {
        events += "done:$name:${if (used) "used" else "unused"}"
    }

    override fun onMovement(edge: String, movement: JSONObject, rate: Double, seconds: Double) {
        events += "movement:$edge"
        movements += edge to movement
        timings += rate to seconds
    }

    override fun onError(code: String, detail: String?) {
        events += "error:$code"
        details += detail
    }
}

/** A player around fakes, with the app's wall clock at [wallStart] when the test starts. */
internal class Rig(
    delivery: String = TestDelivery.json(),
    options: MaskoPlayer.Options = MaskoPlayer.Options(),
    ready: Boolean = true,
    private val wallStart: Long = TestDelivery.WALL_START,
) {
    val time = FakeTime()
    val log = ArrayList<String>()
    val scheduler = FakeScheduler(time)
    val stage = FakeStage(log).also { it.ready = ready }
    val sounds = FakeSounds(log)
    val player = MaskoPlayer(delivery, stage, sounds, scheduler, { time.now }, { wallStart + time.now }, options)
    val heard = Heard().also { player.addListener(it) }
    val slot0 get() = stage.slots[0]
    val slot1 get() = stage.slots[1]

    fun turn() = scheduler.turn()

    fun advance(ms: Long) = scheduler.advance(ms)

    /** Starts and puts the first clip on screen at play time 0. */
    fun started(): Rig {
        turn()
        slot0.firstFrame()
        return this
    }

    /** The log since [mark] (a log size taken earlier). */
    fun since(mark: Int): List<String> = log.subList(mark, log.size).toList()
}

/** A small canvas with every kind of clip the player handles. */
internal object TestDelivery {
    val WALL_START = parseIsoTime("2026-10-23T12:00:00Z")!!

    fun json(
        sig: Int = 1,
        expires: String = "2026-10-23T13:00:00Z",
        contract: Int = 1,
        autoPlay: Boolean = true,
        releaseId: String = "rel-1",
    ): String {
        fun url(name: String) = "https://cdn.test/m/$name?sig=$sig"
        return """
        {
          "deliverySchemaVersion": 1,
          "playerContract": $contract,
          "requires": [],
          "target": "full",
          "mode": "manifest",
          "release": { "id": "$releaseId" },
          "deliveryAccess": { "urlMode": "signed", "signedUrlExpiresAt": "$expires", "lastFetchedAt": "2026-10-23T12:00:00Z" },
          "runtimeGraph": {
            "runtimeGraphSchemaVersion": 1,
            "version": "2.1",
            "name": "Test",
            "initialNode": "idle",
            "autoPlay": $autoPlay,
            "nodes": [
              { "id": "idle", "name": "Idle", "transparentThumbnailUrl": "${url("still-idle.png")}" },
              { "id": "working", "name": "Working", "transparentThumbnailUrl": "${url("still-working.png")}" },
              { "id": "napping", "name": "Napping", "transparentThumbnailUrl": "${url("still-napping.png")}" }
            ],
            "inputs": [
              { "name": "behavior::working", "type": "boolean", "default": false },
              { "name": "behavior::napping", "type": "boolean", "default": false },
              { "name": "action::boop", "type": "trigger", "default": false }
            ],
            "edges": [
              { "id": "loop-idle", "source": "idle", "target": "idle", "isLoop": true, "duration": 2,
                "videos": { "webm": "${url("loop-idle.webm")}", "stacked": "${url("loop-idle.mp4")}",
                  "variants": { "200": { "stacked": "${url("loop-idle-200.mp4")}" }, "800": { "stacked": "${url("loop-idle-800.mp4")}" } } },
                "sound": { "url": "${url("hum.mp3")}", "volume": 0.5, "loop": true } },
              { "id": "boop-idle", "source": "idle", "target": "idle", "isLoop": true, "duration": 1,
                "conditions": [{ "input": "action::boop", "op": "==", "value": true }],
                "videos": { "stacked": "${url("boop-idle.mp4")}" } },
              { "id": "loop-work", "source": "working", "target": "working", "isLoop": true, "duration": 2,
                "hasAudio": true, "videos": { "stacked": "${url("loop-work.mp4")}" } },
              { "id": "to-work", "source": "idle", "target": "working", "isLoop": false, "duration": 1,
                "conditions": [{ "input": "behavior::working", "op": "==", "value": true }],
                "videos": { "stacked": "${url("to-work.mp4")}" },
                "sound": { "url": "${url("whoosh.mp3")}" },
                "movement": { "x": 120, "y": 0 } },
              { "id": "to-idle", "source": "working", "target": "idle", "isLoop": false, "duration": 1,
                "conditions": [{ "input": "behavior::working", "op": "==", "value": false }],
                "videos": { "stacked": "${url("to-idle.mp4")}" } },
              { "id": "to-nap", "source": "idle", "target": "napping", "isLoop": false, "duration": 1,
                "conditions": [{ "input": "behavior::napping", "op": "==", "value": true }],
                "videos": { "webm": "${url("to-nap.webm")}", "hevc": "${url("to-nap.mov")}" } },
              { "id": "nap-wake", "source": "napping", "target": "idle", "isLoop": false, "duration": 1,
                "conditions": [{ "input": "behavior::napping", "op": "==", "value": false }],
                "videos": { "stacked": "${url("nap-wake.mp4")}" } }
            ]
          }
        }
        """.trimIndent()
    }
}
