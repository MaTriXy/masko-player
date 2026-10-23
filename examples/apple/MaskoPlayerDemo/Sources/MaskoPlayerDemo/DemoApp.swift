import AppKit
import MaskoPlayer
import SwiftUI

/// Plays a release delivery (the `delivery` object of
/// `GET /v1/canvases/{canvasId}/releases/{releaseId}/delivery`, saved as JSON)
/// with a few of the calls an app makes:
///
///     swift run MaskoPlayerDemo path/to/delivery.json
@main
struct DemoApp: App {
    @NSApplicationDelegateAdaptor private var delegate: Delegate
    @StateObject private var mascot = Mascot()

    var body: some Scene {
        WindowGroup("Masko player") {
            if let player = mascot.player {
                DemoView(player: player)
            } else {
                Text("swift run MaskoPlayerDemo <delivery.json>").padding()
            }
        }
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// One player for the app's lifetime.
@MainActor
final class Mascot: ObservableObject {
    let player: MaskoPlayer?

    init() {
        let delivery = CommandLine.arguments.dropFirst().first.flatMap {
            try? Data(contentsOf: URL(fileURLWithPath: $0))
        }
        player = delivery.map { MaskoPlayer(delivery: $0) }
    }
}

struct DemoView: View {
    let player: MaskoPlayer
    @State private var working = false
    @State private var sound = false
    @State private var paused = false
    @State private var log: [String] = []

    var body: some View {
        VStack(spacing: 12) {
            MaskoView(player: player)
                .frame(width: 240, height: 240)
            HStack {
                Toggle("Working", isOn: $working)
                    .onChange(of: working) { player.set("working", $0) }
                Button("Celebrate") { player.fire("celebrate") }
                Toggle("Sound", isOn: $sound)
                    .onChange(of: sound) { player.sound = $0 }
                Button(paused ? "Play" : "Pause") {
                    paused ? player.play() : player.pause()
                    paused.toggle()
                }
                Button("Reset") { player.reset() }
            }
            List(Array(log.suffix(12).reversed()), id: \.self) { Text($0).font(.caption.monospaced()) }
                .frame(height: 200)
        }
        .padding()
        .onAppear {
            player.onEvent = { event in log.append("\(log.count + 1). \(event)") }
        }
    }
}
