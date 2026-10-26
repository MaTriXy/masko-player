package ai.masko.player

import ai.masko.player.RealVideoTest.Companion.DELIVERY
import ai.masko.player.RealVideoTest.Companion.SIZE
import android.os.SystemClock
import android.view.View
import android.widget.FrameLayout
import androidx.media3.common.PlaybackException
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** The view around the player on a real device: visibility, surfaces and the slots' decoders. */
@RunWith(AndroidJUnit4::class)
class ViewHostTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val heard: MutableList<String> = Collections.synchronizedList(ArrayList())

    private val listener = object : MaskoPlayer.Listener {
        override fun onClip(clip: String, kind: MaskoPlayer.ClipKind, rate: Double) {
            heard += "clip:$clip"
        }

        override fun onError(code: String, detail: String?) {
            heard += "error:$code:$detail"
        }
    }

    private fun <T> main(f: () -> T): T {
        var result: Result<T>? = null
        instrumentation.runOnMainSync { result = runCatching(f) }
        return result!!.getOrThrow()
    }

    private fun waitFor(what: String, timeoutMs: Long = 10_000, done: () -> Boolean) {
        val until = SystemClock.elapsedRealtime() + timeoutMs
        while (!done()) {
            if (SystemClock.elapsedRealtime() > until) fail("timed out waiting for $what; heard: ${heard.toList()}")
            Thread.sleep(20)
        }
    }

    private fun count(event: String) = synchronized(heard) { heard.count { it == event } }

    @Test
    fun aHiddenViewOrParentPausesThePlayer() {
        ActivityScenario.launch(TestActivity::class.java).use { scenario ->
            lateinit var view: MaskoPlayerView
            lateinit var parent: FrameLayout
            scenario.onActivity { activity ->
                parent = FrameLayout(activity)
                activity.root.addView(parent, FrameLayout.LayoutParams(SIZE, SIZE))
                view = MaskoPlayerView(activity)
                parent.addView(view, FrameLayout.LayoutParams(SIZE, SIZE))
                view.load(DELIVERY).addListener(listener)
            }
            waitFor("the first clip") { count("clip:loop-red") >= 1 }
            assertFalse(main { view.player!!.isPaused })
            main { view.visibility = View.GONE }
            assertTrue("a GONE view pauses", main { view.player!!.isPaused })
            main { view.visibility = View.VISIBLE }
            assertFalse(main { view.player!!.isPaused })
            main { parent.visibility = View.INVISIBLE }
            assertTrue("an INVISIBLE parent pauses", main { view.player!!.isPaused })
            val loops = count("clip:loop-red")
            Thread.sleep(2_500)
            assertEquals("nothing plays meanwhile", loops, count("clip:loop-red"))
            main { parent.visibility = View.VISIBLE }
            assertFalse(main { view.player!!.isPaused })
            waitFor("the loop going on") { count("clip:loop-red") > loops }
            main { view.player!!.destroy() }
        }
        assertTrue("errors: $heard", heard.none { it.startsWith("error:") })
    }

    @Test
    fun withPointerOffTheViewTakesNoTaps() {
        ActivityScenario.launch(TestActivity::class.java).use { scenario ->
            lateinit var view: MaskoPlayerView
            scenario.onActivity { activity ->
                view = MaskoPlayerView(activity)
                view.pointer = false
                activity.root.addView(view, FrameLayout.LayoutParams(SIZE, SIZE))
                view.load(DELIVERY).addListener(listener)
            }
            waitFor("the first clip") { count("clip:loop-red") >= 1 }
            assertFalse(main { view.isClickable })
            assertFalse("no click listener runs", main { view.performClick() })
            main { view.pointer = true }
            assertTrue(main { view.isClickable })
            assertTrue("the click reaches the player", main { view.performClick() })
            main { view.player!!.destroy() }
        }
        assertTrue("errors: $heard", heard.none { it.startsWith("error:") })
    }

    @Test
    fun aViewWithNoHeightSaysSoAndPlaysOnceItHasOne() {
        ActivityScenario.launch(TestActivity::class.java).use { scenario ->
            lateinit var view: MaskoPlayerView
            scenario.onActivity { activity ->
                view = MaskoPlayerView(activity)
                activity.root.addView(view, FrameLayout.LayoutParams(SIZE, 0))
                view.load(DELIVERY).addListener(listener)
            }
            waitFor("surface_unavailable", timeoutMs = 5_000) { heard.isNotEmpty() }
            assertEquals(listOf("error:surface_unavailable:the view is $SIZE x 0 pixels"), heard.toList())
            main { view.layoutParams = FrameLayout.LayoutParams(SIZE, SIZE) }
            waitFor("the first clip") { count("clip:loop-red") >= 1 }
            main { view.player!!.destroy() }
        }
    }

    @Test
    fun aViewInASoftwareLayerSaysItHasNoSurface() {
        ActivityScenario.launch(TestActivity::class.java).use { scenario ->
            lateinit var view: MaskoPlayerView
            scenario.onActivity { activity ->
                val parent = FrameLayout(activity).apply { setLayerType(View.LAYER_TYPE_SOFTWARE, null) }
                activity.root.addView(parent, FrameLayout.LayoutParams(SIZE, SIZE))
                view = MaskoPlayerView(activity)
                parent.addView(view, FrameLayout.LayoutParams(SIZE, SIZE))
                view.load(DELIVERY).addListener(listener)
            }
            waitFor("surface_unavailable", timeoutMs = 5_000) { heard.isNotEmpty() }
            assertEquals(
                listOf("error:surface_unavailable:the video got no surface; is a parent drawn in a software layer?"),
                heard.toList(),
            )
            main { view.player!!.destroy() }
        }
    }

    @Test
    fun anErrorOfTheClipLoadedBeforeIsNotBlamedOnTheNewOne() {
        ActivityScenario.launch(TestActivity::class.java).use { scenario ->
            lateinit var video: StackedVideoView
            scenario.onActivity { activity ->
                video = StackedVideoView(activity)
                activity.root.addView(video, FrameLayout.LayoutParams(SIZE, SIZE))
            }
            waitFor("a surface") { main { video.hasHost } }
            val failures: MutableList<String> = Collections.synchronizedList(ArrayList())
            var frames = 0
            val slot = main {
                ExoClipSlot(video.context, video, MediaFiles.get(video.context)) {}.also {
                    it.events = object : ClipSlot.Events {
                        override fun onFirstFrame() {
                            frames++
                        }

                        override fun onEnded() {}

                        override fun onFailed(message: String) {
                            failures += message
                        }
                    }
                    it.load("asset:///clips/red.mp4")
                }
            }
            waitFor("red's first frame") { main { frames } == 1 }
            main {
                slot.load("asset:///clips/blue.mp4")
                // The decoder reports an error of red before blue is in the player.
                slot.onPlayerError(PlaybackException("red failed", null, PlaybackException.ERROR_CODE_DECODING_FAILED))
            }
            waitFor("blue's first frame") { main { frames } == 2 }
            assertEquals("nothing blamed on blue", emptyList<String>(), failures.toList())
            // Once blue is in the player, an error is blue's.
            main { slot.onPlayerError(PlaybackException("blue failed", null, PlaybackException.ERROR_CODE_DECODING_FAILED)) }
            assertEquals(listOf("ERROR_CODE_DECODING_FAILED"), failures.toList())
            main { slot.release() }
        }
    }

    @Test
    fun anOutputMadeWhileTheSurfaceDiesIsFreed() {
        ActivityScenario.launch(TestActivity::class.java).use { scenario ->
            lateinit var video: StackedVideoView
            scenario.onActivity { activity ->
                video = StackedVideoView(activity)
                activity.root.addView(video, FrameLayout.LayoutParams(SIZE, SIZE))
            }
            waitFor("a surface") { main { video.hasHost } }
            val gate = CountDownLatch(1)
            var handedOver = false
            main {
                video.createOutput { handedOver = true }
                // The GL thread makes the output, then waits here; its teardown queues behind.
                video.onGlThread { gate.await(10, TimeUnit.SECONDS) }
                val until = SystemClock.elapsedRealtime() + 5_000
                while (video.liveOutputs.get() == 0 && SystemClock.elapsedRealtime() < until) Thread.sleep(5)
                assertEquals("the output is made", 1, video.liveOutputs.get())
                // The surface dies before the output reaches the main thread.
                (video.parent as FrameLayout).removeView(video)
            }
            // The main thread has handed the output back by now; let the GL thread tear down.
            instrumentation.waitForIdleSync()
            gate.countDown()
            waitFor("every output freed") { video.liveOutputs.get() == 0 }
            assertFalse("no decoder got an output of a dead surface", handedOver)
        }
    }

    @Test
    fun destroyCancelsThePreloadsAndStillsTheStageWaitsFor() {
        ActivityScenario.launch(TestActivity::class.java).use { scenario ->
            lateinit var view: MaskoPlayerView
            scenario.onActivity { activity ->
                view = MaskoPlayerView(activity)
                activity.root.addView(view, FrameLayout.LayoutParams(SIZE, SIZE))
            }
            val called: MutableList<String> = Collections.synchronizedList(ArrayList())
            main {
                val stage = ViewStage(view, MediaFiles.get(view.context))
                stage.preload("https://example.invalid/masko-player-test/never.mp4") { called += "preload $it" }
                stage.preload("asset:///clips/red.mp4") { called += "local $it" }
                stage.showStill("asset:///clips/red.mp4") { called += "still" }
                assertEquals(3, stage.pending)
                stage.release()
                assertEquals(0, stage.pending)
            }
            Thread.sleep(3_000)
            assertEquals("nothing called back after release", emptyList<String>(), called.toList())
            // Not released, they do call back.
            val stage = main {
                ViewStage(view, MediaFiles.get(view.context)).also {
                    it.preload("asset:///clips/red.mp4") { ok -> called += "local $ok" }
                    it.showStill("asset:///clips/red.mp4") { called += "still" }
                }
            }
            waitFor("the callbacks") { called.size == 2 }
            assertTrue(called.containsAll(listOf("local true", "still")))
            assertEquals(0, main { stage.pending })
            main { stage.release() }
        }
    }
}
