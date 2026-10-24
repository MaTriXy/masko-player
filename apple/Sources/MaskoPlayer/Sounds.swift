import AVFoundation

/// Plays edge sounds (rules.md 9.6).
@MainActor
protocol SoundOutput: AnyObject {
    func play(_ file: URL, volume: Double, loop: Bool)
    /// Stops looping sounds, or every sound.
    func stop(onlyLooping: Bool)
    func pause()
    func resume()
}

/// Edge sounds on `AVPlayer`s: a looping sound on an `AVPlayerLooper`, a
/// one-shot sound until it ends. The app chooses its audio session.
@MainActor
final class AVSounds: SoundOutput {
    private final class Playing {
        let player: AVPlayer
        let loop: Bool
        let looper: AVPlayerLooper?
        var observer: NSObjectProtocol?

        init(player: AVPlayer, loop: Bool, looper: AVPlayerLooper?) {
            self.player = player
            self.loop = loop
            self.looper = looper
        }
    }

    private var playing: [Playing] = []
    private var paused = false

    func play(_ file: URL, volume: Double, loop: Bool) {
        let sound: Playing
        if loop {
            let queue = AVQueuePlayer()
            let looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: file))
            sound = Playing(player: queue, loop: true, looper: looper)
        } else {
            let item = AVPlayerItem(url: file)
            sound = Playing(player: AVPlayer(playerItem: item), loop: false, looper: nil)
            sound.observer = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { [weak self, id = ObjectIdentifier(sound)] _ in
                MainActor.assumeIsolated {
                    self?.remove { ObjectIdentifier($0) == id }
                }
            }
        }
        sound.player.volume = Float(volume)
        #if !os(visionOS)
        sound.player.preventsDisplaySleepDuringVideoPlayback = false
        #endif
        playing.append(sound)
        if !paused {
            sound.player.play()
        }
    }

    func stop(onlyLooping: Bool) {
        remove { !onlyLooping || $0.loop }
    }

    func pause() {
        paused = true
        playing.forEach { $0.player.pause() }
    }

    func resume() {
        paused = false
        playing.forEach { $0.player.play() }
    }

    private func remove(where match: (Playing) -> Bool) {
        for sound in playing where match(sound) {
            sound.looper?.disableLooping()
            sound.player.pause()
            if let queue = sound.player as? AVQueuePlayer {
                queue.removeAllItems()
            } else {
                sound.player.replaceCurrentItem(with: nil)
            }
            if let observer = sound.observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        playing.removeAll(where: match)
    }
}
