package ai.masko.player.demo

import ai.masko.player.MaskoPlayer
import ai.masko.player.MaskoPlayerView
import android.app.Activity
import android.os.Bundle
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView
import java.io.File

/**
 * Plays a release delivery (the `delivery` object of
 * `GET /v1/canvases/{canvasId}/releases/{releaseId}/delivery`, saved as JSON)
 * with a few of the calls an app makes. Without one it plays a bundled demo
 * made of the library's stacked test clips. From the repository root, after
 * `scripts/build-android.sh`:
 *
 *     android/gradlew -p examples/android :app:installDebug
 *
 * To play your own delivery, push it and restart the app:
 *
 *     adb push delivery.json /sdcard/Android/data/ai.masko.player.demo/files/delivery.json
 */
class MainActivity : Activity() {
    private lateinit var player: MaskoPlayer
    private val log = ArrayList<String>()
    private lateinit var logView: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val density = resources.displayMetrics.density
        val mascot = MaskoPlayerView(this)
        logView = TextView(this).apply { typeface = android.graphics.Typeface.MONOSPACE; textSize = 12f }

        val own = getExternalFilesDir(null)?.let { File(it, "delivery.json") }?.takeIf { it.exists() }
        val delivery = own?.readText() ?: assets.open("demo-delivery.json").bufferedReader().readText()
        player = mascot.load(delivery)
        player.addListener(object : MaskoPlayer.Listener {
            override fun onPose(pose: String) = add("pose $pose")
            override fun onClip(clip: String, kind: MaskoPlayer.ClipKind, rate: Double) = add("clip $clip")
            override fun onReactionDone(name: String, used: Boolean) = add("done $name${if (used) "" else " (unused)"}")
            override fun onMovement(edge: String, movement: org.json.JSONObject, rate: Double, seconds: Double) =
                add("movement $edge $movement ${seconds}s")
            override fun onError(code: String, detail: String?) = add("error $code${detail?.let { " ($it)" } ?: ""}")
        })

        val controls = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(Switch(context).apply {
                text = "Working"
                setOnCheckedChangeListener { _, on -> player.set("working", on) }
            })
            addView(Button(context).apply {
                text = "Celebrate"
                setOnClickListener { player.fire("celebrate") }
            })
            addView(Switch(context).apply {
                text = "Sound"
                setOnCheckedChangeListener { _, on -> player.sound = on }
            })
        }
        val transport = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            addView(Button(context).apply {
                text = "Pause"
                setOnClickListener {
                    if (player.isPaused) player.play() else player.pause()
                    text = if (player.isPaused) "Play" else "Pause"
                }
            })
            addView(Button(context).apply {
                text = "Reset"
                setOnClickListener { player.reset() }
            })
        }
        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding((16 * density).toInt(), (16 * density).toInt(), (16 * density).toInt(), 0)
            addView(TextView(context).apply { text = if (own != null) "Your delivery" else "Bundled demo" })
            addView(mascot, LinearLayout.LayoutParams((240 * density).toInt(), (240 * density).toInt()))
            addView(controls, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
            addView(transport, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
            addView(ScrollView(context).apply { addView(logView) }, LinearLayout.LayoutParams(MATCH_PARENT, 0, 1f))
        })
    }

    private fun add(line: String) {
        log += "${log.size + 1}. $line"
        logView.text = log.takeLast(14).reversed().joinToString("\n")
    }

    override fun onDestroy() {
        player.destroy()
        super.onDestroy()
    }
}
