import SwiftUI

/// A `MaskoPlayer` in SwiftUI: `MaskoView(player: player)`.
public struct MaskoView {
    public let player: MaskoPlayer

    public init(player: MaskoPlayer) {
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
