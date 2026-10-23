package ai.masko.player.reactnative

import ai.masko.player.MaskoPlayer
import ai.masko.player.MaskoPlayerView
import android.content.Context
import expo.modules.kotlin.AppContext
import expo.modules.kotlin.viewevent.EventDispatcher
import expo.modules.kotlin.views.ExpoView
import org.json.JSONArray
import org.json.JSONObject

/**
 * Shows one [MaskoPlayer] in a [MaskoPlayerView]. A new delivery, or
 * `getDelivery` given or taken away, loads a new player; the view going away
 * destroys it.
 */
class MaskoNativeView(context: Context, appContext: AppContext) : ExpoView(context, appContext) {
  // The video slots are Android views: let Android lay them out inside the size React Native gives.
  override val shouldUseAndroidLayout = true

  private val onPose by EventDispatcher()
  private val onClip by EventDispatcher()
  private val onReactionDone by EventDispatcher()
  private val onMovement by EventDispatcher()
  private val onError by EventDispatcher()
  private val onDeliveryRequest by EventDispatcher()

  var delivery: String? = null
  var autoPlay: Boolean? = null
  var sound = false
  var refreshes = false

  var player: MaskoPlayer? = null
    private set

  private val mascot = MaskoPlayerView(context)

  /** What the player was loaded with. */
  private var loaded: Pair<String, Boolean>? = null

  /** `getDelivery` calls waiting for JavaScript's answer. */
  private val requests = HashMap<Int, (String?) -> Unit>()
  private var lastRequest = 0

  private val listener = object : MaskoPlayer.Listener {
    override fun onPose(pose: String) = this@MaskoNativeView.onPose(mapOf("pose" to pose))

    override fun onClip(clip: String, kind: MaskoPlayer.ClipKind, rate: Double) =
      this@MaskoNativeView.onClip(mapOf("clip" to clip, "kind" to kind.name.lowercase(), "rate" to rate))

    override fun onReactionDone(name: String, used: Boolean) =
      this@MaskoNativeView.onReactionDone(mapOf("name" to name, "used" to used))

    override fun onMovement(edge: String, movement: JSONObject, rate: Double, seconds: Double) =
      this@MaskoNativeView.onMovement(
        mapOf(
          "edge" to edge,
          "movement" to (plain(movement) ?: emptyMap<String, Any>()),
          "rate" to rate,
          "seconds" to seconds,
        ),
      )

    override fun onError(code: String, detail: String?) =
      this@MaskoNativeView.onError(if (detail == null) mapOf("code" to code) else mapOf("code" to code, "detail" to detail))
  }

  init {
    addView(mascot, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
  }

  fun propsChanged() {
    val json = delivery ?: return unload()
    if (loaded != json to refreshes) load(json)
    player?.sound = sound
  }

  fun position(): Map<String, Any?> {
    val position = player?.position()
    return mapOf("clip" to position?.clip, "time" to (position?.time ?: 0.0))
  }

  /** New links for the release that is playing: the player swaps them in. */
  fun updateDelivery(json: String) {
    player?.updateDelivery(json)
  }

  fun answerDelivery(request: Int, json: String?) {
    requests.remove(request)?.invoke(json)
  }

  fun unload() {
    answerAll()
    player?.destroy()
    player = null
    loaded = null
  }

  private fun load(json: String) {
    unload()
    val source = if (refreshes) MaskoPlayer.DeliverySource(::requestDelivery) else null
    val next = mascot.load(json, MaskoPlayer.Options(autoPlay = autoPlay, sound = sound, getDelivery = source))
    next.addListener(listener)
    player = next
    loaded = json to refreshes
  }

  /** Asks JavaScript's `getDelivery` (the player asks on the main thread); [answerDelivery] replies. */
  private fun requestDelivery(reply: (String?) -> Unit) {
    val request = ++lastRequest
    requests[request] = reply
    onDeliveryRequest(mapOf("request" to request))
  }

  private fun answerAll() {
    val waiting = requests.values.toList()
    requests.clear()
    waiting.forEach { it(null) }
  }
}

/** A JSON value as maps, lists and plain values, for JavaScript. */
private fun plain(value: Any?): Any? = when (value) {
  is JSONObject -> value.keys().asSequence().associateWith { plain(value.opt(it)) }
  is JSONArray -> (0 until value.length()).map { plain(value.opt(it)) }
  JSONObject.NULL -> null
  else -> value
}
