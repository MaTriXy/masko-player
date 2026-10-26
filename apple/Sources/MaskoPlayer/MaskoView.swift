import SwiftUI

/// A `MaskoPlayer` in SwiftUI: `MaskoView(player: player)`. With `pointer`
/// off the view takes no clicks, taps or pointer, and the app sends them
/// itself (`MaskoPlayerView.pointer`).
public struct MaskoView {
    public let player: MaskoPlayer
    public let pointer: Bool

    public init(player: MaskoPlayer, pointer: Bool = true) {
        self.player = player
        self.pointer = pointer
    }
}

#if canImport(UIKit)
extension MaskoView: UIViewRepresentable {
    public func makeUIView(context: Context) -> MaskoPlayerView {
        MaskoPlayerView(player: player, pointer: pointer)
    }

    public func updateUIView(_ view: MaskoPlayerView, context: Context) {
        view.player = player
        view.pointer = pointer
    }
}

#elseif canImport(AppKit)
extension MaskoView: NSViewRepresentable {
    public func makeNSView(context: Context) -> MaskoPlayerView {
        MaskoPlayerView(player: player, pointer: pointer)
    }

    public func updateNSView(_ view: MaskoPlayerView, context: Context) {
        view.player = player
        view.pointer = pointer
    }
}
#endif
