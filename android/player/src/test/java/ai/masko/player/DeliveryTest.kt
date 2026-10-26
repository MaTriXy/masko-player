package ai.masko.player

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DeliveryTest {
    private val delivery = Delivery.parse(TestDelivery.json())!!

    @Test
    fun readsWhatThePlayerNeeds() {
        val idle = delivery.edges.getValue("loop-idle")
        assertEquals(listOf(200, 800), idle.variants.map { it.first })
        assertEquals(0.5f, idle.sound!!.volume, 0f)
        assertTrue(idle.sound!!.loop)
        assertTrue(delivery.edges.getValue("loop-work").hasAudio)
        assertEquals(120, delivery.edges.getValue("to-work").movement!!.getInt("x"))
        assertEquals(1.0, delivery.edges.getValue("to-work").duration, 0.0)
        assertNull("no stacked file", delivery.edges.getValue("to-nap").video(300))
        assertEquals("https://cdn.test/m/still-idle.png?sig=1", delivery.stills["idle"])
        assertEquals("loop-work", delivery.mainClip("working"))
        assertNull(delivery.mainClip("napping"))
        assertEquals(parseIsoTime("2026-10-23T13:00:00Z"), delivery.expiresAt)
        assertTrue(delivery.autoPlay)
    }

    @Test
    fun anAv1FileWinsOverTheStackedOne() {
        val json = TestDelivery.json()
            .replace("\"stacked\": \"https://cdn.test/m/loop-idle.mp4", "\"av1\": \"https://cdn.test/m/loop-idle-av1.mp4\", \"stacked\": \"https://cdn.test/m/loop-idle.mp4")
        val idle = Delivery.parse(json)!!.edges.getValue("loop-idle")
        assertEquals("https://cdn.test/m/loop-idle-av1.mp4", idle.video(0))
    }

    @Test
    fun aRefreshMustBeTheSameRelease() {
        assertTrue(delivery.sameRelease(Delivery.parse(TestDelivery.json(sig = 2))!!))
        assertFalse(delivery.sameRelease(Delivery.parse(TestDelivery.json(releaseId = "rel-2"))!!))
        val renamed = TestDelivery.json(sig = 2).replace("\"name\": \"Test\"", "\"name\": \"Other\"")
        assertFalse("another graph", delivery.sameRelease(Delivery.parse(renamed)!!))
        assertNull(Delivery.parse("not json"))
    }

    @Test
    fun readsIsoTimes() {
        assertEquals(1_792_756_800_000L, parseIsoTime("2026-10-23T12:00:00Z"))
        assertEquals(1_792_756_800_123L, parseIsoTime("2026-10-23T12:00:00.123456Z"))
        assertEquals(1_792_756_800_000L, parseIsoTime("2026-10-23T21:00:00+09:00"))
        assertEquals(1_792_756_800_000L, parseIsoTime("2026-10-23T07:00:00-0500"))
        assertNull(parseIsoTime("tomorrow"))
    }

    @Test
    fun theSizeIsTheFittedMascotsNotTheViews() {
        // A square mascot (or one not known yet) in a wide view is as tall as the view.
        assertEquals(300, fittedSizePx(1_000, 300, null))
        assertEquals(300, fittedSizePx(300, 1_000, 1f))
        // A mascot twice as wide as tall, in a tall view: as wide as the view.
        assertEquals(300, fittedSizePx(300, 1_000, 2f))
        assertEquals(600, fittedSizePx(1_000, 300, 2f))
        // Twice as tall as wide, in a wide view: as tall as the view.
        assertEquals(300, fittedSizePx(1_000, 300, 0.5f))
        assertEquals(0, fittedSizePx(0, 300, null))
        assertEquals("loop-idle-800.mp4", short(delivery.edges.getValue("loop-idle").video(fittedSizePx(1_000, 300, null))))
    }

    @Test
    fun aFileKeyIgnoresTheSignature() {
        assertEquals(fileKey("https://a.test/x.mp4?sig=1"), fileKey("https://a.test/x.mp4?sig=2&e=3"))
    }
}
