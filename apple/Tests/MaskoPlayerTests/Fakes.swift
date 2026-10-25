import CoreGraphics
import Foundation

@testable import MaskoPlayer

/// A scripted video slot: the test says when the first frame is decoded,
/// when a load fails, and when the clip ends.
@MainActor
final class FakeSlot: VideoSlot {
    let name: String
    var onEnd: (@MainActor () -> Void)?
    var onFail: (@MainActor () -> Void)?
    var isMuted = true
    var clipTime = 0.0

    private(set) var file: URL?
    private(set) var frameDecoded = false
    private(set) var played = false
    private(set) var playing = false
    private(set) var rate: Double?
    private(set) var log: [String] = []
    private var ready: (@MainActor (Bool) -> Void)?

    init(name: String) {
        self.name = name
    }

    /// The file name loaded, for short assertions.
    var clip: String? { file?.deletingPathExtension().lastPathComponent }
    var isLoading: Bool { ready != nil }

    func load(_ file: URL, ready: @escaping @MainActor (Bool) -> Void) {
        playing = false
        if file == self.file, !played {
            if frameDecoded {
                log.append("reuse \(file.lastPathComponent)")
                ready(true)
            } else {
                self.ready = ready
            }
            return
        }
        log.append("load \(file.lastPathComponent)")
        self.file = file
        frameDecoded = false
        played = false
        self.ready = ready
    }

    /// The decoder has the first frame.
    func decodeFirstFrame() {
        frameDecoded = true
        let done = ready
        ready = nil
        done?(true)
    }

    func failLoad() {
        file = nil
        let done = ready
        ready = nil
        done?(false)
    }

    func play(rate: Double) {
        log.append("play \(rate)")
        played = true
        playing = true
        self.rate = rate
    }

    func restart(rate: Double) {
        log.append("restart \(rate)")
        played = true
        playing = true
        clipTime = 0
        self.rate = rate
    }

    func pause() {
        log.append("pause")
        playing = false
    }

    /// The clip plays its last frame.
    func end() {
        playing = false
        onEnd?()
    }

    func failWhilePlaying() {
        playing = false
        onFail?()
    }
}

@MainActor
final class FakeStage: Stage {
    let fakeSlots = [FakeSlot(name: "a"), FakeSlot(name: "b")]
    var slots: [VideoSlot] { fakeSlots }
    private(set) var presented: [StageContent] = []
    /// Swaps to a slot whose first frame was not decoded yet.
    private(set) var swapsWithoutFrame = 0

    func present(_ content: StageContent) {
        if case let .slot(i) = content, !fakeSlots[i].frameDecoded {
            swapsWithoutFrame += 1
        }
        presented.append(content)
    }

    var showing: StageContent? { presented.last }
}

/// Hands back files at once, or fails the URLs it is told to, or holds them
/// until the test releases them.
@MainActor
final class FakeLoader: MediaLoader {
    var failing: Set<String> = []
    var holding = false
    private(set) var requests: [(url: URL, key: String)] = []
    private var held: [(URL, @MainActor (URL?) -> Void)] = []
    static let image: CGImage = {
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }()

    func file(_ url: URL, key: String, done: @escaping @MainActor (URL?) -> Void) {
        requests.append((url, key))
        if holding {
            held.append((url, done))
        } else {
            done(failing.contains(url.lastPathComponent) ? nil : url)
        }
    }

    func image(_ url: URL, key: String, done: @escaping @MainActor (CGImage?) -> Void) {
        file(url, key: key) { local in done(local == nil ? nil : FakeLoader.image) }
    }

    /// File lengths by file name, for `length`; a name not here cannot be read.
    var lengths: [String: TimeInterval] = [:]

    func length(_ url: URL, key: String, done: @escaping @MainActor (TimeInterval?) -> Void) {
        file(url, key: key) { [unowned self] local in
            done(local == nil ? nil : self.lengths[url.lastPathComponent])
        }
    }

    func release() {
        let waiting = held
        held = []
        for (url, done) in waiting {
            done(failing.contains(url.lastPathComponent) ? nil : url)
        }
    }

    func requested(_ name: String) -> Bool {
        requests.contains { $0.url.lastPathComponent == name }
    }
}

@MainActor
final class FakeSounds: SoundOutput {
    private(set) var log: [String] = []

    func play(_ file: URL, volume: Double, loop: Bool) {
        log.append("play \(file.deletingPathExtension().lastPathComponent) \(volume)\(loop ? " loop" : "")")
    }

    func stop(onlyLooping: Bool) {
        log.append(onlyLooping ? "stop looping" : "stop all")
    }

    func pause() {
        log.append("pause")
    }

    func resume() {
        log.append("resume")
    }
}

/// A clock the test moves by hand, with the timers due on it.
@MainActor
final class FakeHost {
    var uptime: TimeInterval = 100
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    private var timers: [(id: Int, due: TimeInterval, action: @MainActor () -> Void)] = []
    private(set) var wallTimers: [(id: Int, date: Date, action: @MainActor () -> Void)] = []
    private var nextID = 0

    var host: PlayerHost {
        PlayerHost(
            uptime: { self.uptime },
            date: { self.date },
            after: { delay, action in
                self.nextID += 1
                let id = self.nextID
                self.timers.append((id, self.uptime + delay, action))
                return Cancellation { [weak self] in
                    MainActor.assumeIsolated { self?.timers.removeAll { $0.id == id } }
                }
            },
            at: { date, action in
                self.nextID += 1
                let id = self.nextID
                self.wallTimers.append((id, date, action))
                return Cancellation { [weak self] in
                    MainActor.assumeIsolated { self?.wallTimers.removeAll { $0.id == id } }
                }
            }
        )
    }

    var pendingTimers: Int { timers.count }

    /// Moves time on by `seconds`, running every timer that comes due, in
    /// order, at its own time.
    func advance(_ seconds: TimeInterval) {
        let until = uptime + seconds
        while let next = timers.filter({ $0.due <= until }).min(by: { $0.due < $1.due }) {
            timers.removeAll { $0.id == next.id }
            uptime = max(uptime, next.due)
            next.action()
        }
        uptime = until
    }

    /// Moves the wall clock to the first wall timer and runs it.
    func runWallTimer() {
        guard let next = wallTimers.min(by: { $0.date < $1.date }) else { return }
        wallTimers.removeAll { $0.id == next.id }
        date = max(date, next.date)
        next.action()
    }
}
