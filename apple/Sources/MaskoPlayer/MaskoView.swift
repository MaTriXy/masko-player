import SwiftUI

/// A `MaskoPlayer` in SwiftUI: `MaskoView(player: player)`. The view does not
/// watch the person: the app sets `behavior::pointerHover` and fires
/// `action::click` itself, with SwiftUI's own gestures (rules.md 3.5).
public struct MaskoView {
    public let player: MaskoPlayer

    public init(player: MaskoPlayer) {
        self.player = player
    }

    @available(*, deprecated, message: "The view no longer watches the pointer: use init(player:).")
    public init(player: MaskoPlayer, pointer: Bool) {
        self.player = player
    }
}

#if canImport(UIKit)
extension MaskoView: UIViewRepresentable {
    public func makeUIView(context: Context) -> MaskoPlayerView {
        MaskoPlayerView(player: player)
    }

    public func updateUIView(_ view: MaskoPlayerView, context: Context) {
        view.player = player
    }
}

#elseif canImport(AppKit)
extension MaskoView: NSViewRepresentable {
    public func makeNSView(context: Context) -> MaskoPlayerView {
        MaskoPlayerView(player: player)
    }

    public func updateNSView(_ view: MaskoPlayerView, context: Context) {
        view.player = player
    }
}
#endif
