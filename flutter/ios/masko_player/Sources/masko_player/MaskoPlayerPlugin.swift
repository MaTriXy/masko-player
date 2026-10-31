import Flutter
import UIKit

#if canImport(MaskoPlayer)
import MaskoPlayer
#endif

/// Registers the `MaskoView` platform view and answers `maskoFormats()`.
public final class MaskoPlayerPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "ai.masko.player", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(MaskoPlayerPlugin(), channel: channel)
        registrar.register(MaskoViewFactory(messenger: registrar.messenger()), withId: "ai.masko.player/view")
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        // The formats to ask the release delivery for (formats=...).
        case "formats": result(MaskoPlayer.formats)
        default: result(FlutterMethodNotImplemented)
        }
    }
}

/// Makes a `MaskoFlutterView` for each `MaskoView`, with the widget's props
/// as creation params.
final class MaskoViewFactory: NSObject, FlutterPlatformViewFactory {
    private let messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
    }

    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        MainActor.assumeIsolated {
            MaskoFlutterView(arguments: args as? [String: Any] ?? [:], messenger: messenger)
        }
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }
}
