package ai.masko.player.flutter

import ai.masko.player.MaskoPlayer
import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory

/** Registers the `MaskoView` platform view and answers `maskoFormats()`. */
class MaskoPlayerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
  private lateinit var channel: MethodChannel

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(binding.binaryMessenger, "ai.masko.player")
    channel.setMethodCallHandler(this)
    binding.platformViewRegistry.registerViewFactory("ai.masko.player/view", MaskoViewFactory(binding.binaryMessenger))
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      // The formats to ask the release delivery for (formats=...).
      "formats" -> result.success(MaskoPlayer.formats)
      else -> result.notImplemented()
    }
  }
}

/** Makes a [MaskoFlutterView] for each `MaskoView`, with the widget's props as creation params. */
private class MaskoViewFactory(private val messenger: BinaryMessenger) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
  override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
    @Suppress("UNCHECKED_CAST")
    return MaskoFlutterView(context, messenger, args as? Map<String, Any?> ?: emptyMap())
  }
}
