import AVFoundation
import QuartzCore

/// One of the two persistent video surfaces (player.md, `showClip`).
@MainActor
protocol VideoSlot: AnyObject {
    /// Loads a file paused on its first frame, and calls `ready(true)` once
    /// that frame is decoded, or `ready(false)` when the file cannot play. A
    /// later `load` replaces an earlier one, whose callback never comes.
    /// Loading again a file loaded ahead and not played yet is ready at once.
    func load(_ file: URL, ready: @escaping @MainActor (Bool) -> Void)
    /// Plays from the frame on screen at this rate.
    func play(rate: Double)
    /// Seeks to the first frame and plays at this rate: the next loop.
    func restart(rate: Double)
    func pause()
    /// Seconds into the file.
    var clipTime: Double { get }
    var isMuted: Bool { get set }
    /// The clip played its last frame.
    var onEnd: (@MainActor () -> Void)? { get set }
    /// The clip stopped playing on an error.
    var onFail: (@MainActor () -> Void)? { get set }
}

/// What the stage shows: one of the slots, or a still image (or nothing).
enum StageContent: Equatable {
    case slot(Int)
    case still(CGImage?)
}

/// The two slots and the still image, drawn in one place.
@MainActor
protocol Stage: AnyObject {
    /// Exactly two.
    var slots: [VideoSlot] { get }
    /// Shows this and hides everything else in the same frame, with implicit
    /// animations off. No crossfade, ever.
    func present(_ content: StageContent)
}

// MARK: - AVFoundation

/// A slot backed by an `AVPlayer` and its `AVPlayerLayer`. A clip is ready
/// when an `AVPlayerItemVideoOutput` on its item holds a decoded frame and the
/// layer says that frame is ready for display (`isReadyForDisplay`), so it
/// shows on the first frame the layer is visible.
@MainActor
final class AVSlot: VideoSlot {
    let player = AVPlayer()
    let layer: AVPlayerLayer
    var onEnd: (@MainActor () -> Void)?
    var onFail: (@MainActor () -> Void)?

    private(set) var file: URL?
    /// The first frame of the loaded file, decoded, until it plays.
    private(set) var firstFrame: CVPixelBuffer?
    private var output: AVPlayerItemVideoOutput?
    private var ready: (@MainActor (Bool) -> Void)?
    private var played = false
    private var poll: Timer?
    private var loadStarted = Date()
    /// When the video output first held a decoded frame.
    private var decodedAt: Date?
    private var observers: [NSObjectProtocol] = []
    /// A file that never shows a frame counts as failed after this long.
    private let loadTimeout: TimeInterval = 10
    /// The layer reports its frame within a millisecond of the output; one
    /// that never does is trusted after this long.
    private let layerGrace: TimeInterval = 0.1

    init() {
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = true
        layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.isHidden = true
    }

    var isMuted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }

    var clipTime: Double {
        let t = player.currentTime().seconds
        return t.isFinite ? max(t, 0) : 0
    }

    func load(_ file: URL, ready: @escaping @MainActor (Bool) -> Void) {
        player.pause()
        if file == self.file, !played {
            if firstFrame != nil {
                // Loaded ahead and still on its first frame.
                ready(true)
            } else {
                // Still loading: the running check calls the new callback.
                self.ready = ready
            }
            return
        }
        stopWatching()
        self.file = file
        self.ready = ready
        played = false
        loadStarted = Date()
        decodedAt = nil
        let item = AVPlayerItem(url: file)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        item.add(output)
        self.output = output
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onEnd?() }
            },
            center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onFail?() }
            },
        ]
        player.replaceCurrentItem(with: item)
        let timer = Timer(timeInterval: 1.0 / 240, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    private func check() {
        guard let item = player.currentItem else { return }
        if item.status == .failed || Date().timeIntervalSince(loadStarted) > loadTimeout {
            finishLoad(false)
            return
        }
        guard item.status == .readyToPlay else { return }
        let time = item.currentTime()
        if let output, output.hasNewPixelBuffer(forItemTime: time),
            let frame = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
        {
            firstFrame = frame
            decodedAt = Date()
            // Only the first frame needed checking.
            item.remove(output)
            self.output = nil
        }
        if let decodedAt, layer.isReadyForDisplay || Date().timeIntervalSince(decodedAt) > layerGrace {
            finishLoad(true)
        }
    }

    private func finishLoad(_ ok: Bool) {
        poll?.invalidate()
        poll = nil
        if !ok {
            stopWatching()
            file = nil
            player.replaceCurrentItem(with: nil)
        }
        let done = ready
        ready = nil
        done?(ok)
    }

    func play(rate: Double) {
        played = true
        firstFrame = nil
        player.playImmediately(atRate: Float(rate))
    }

    func restart(rate: Double) {
        played = true
        firstFrame = nil
        player.pause()
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        player.playImmediately(atRate: Float(rate))
    }

    func pause() {
        player.pause()
    }

    /// Lets go of the file.
    func unload() {
        stopWatching()
        ready = nil
        file = nil
        player.replaceCurrentItem(with: nil)
    }

    private func stopWatching() {
        poll?.invalidate()
        poll = nil
        output = nil
        firstFrame = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}

/// The real stage: two `AVPlayerLayer`s and a still layer in one container
/// layer, which `MaskoPlayerView` hosts.
@MainActor
final class AVStage: Stage {
    let layer = CALayer()
    let stillLayer = CALayer()
    let avSlots = [AVSlot(), AVSlot()]
    var slots: [VideoSlot] { avSlots }

    init() {
        stillLayer.contentsGravity = .resizeAspect
        stillLayer.isHidden = true
        for slot in avSlots {
            layer.addSublayer(slot.layer)
        }
        layer.addSublayer(stillLayer)
    }

    func present(_ content: StageContent) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, slot) in avSlots.enumerated() {
            slot.layer.isHidden = content != .slot(i)
        }
        switch content {
        case .slot:
            stillLayer.isHidden = true
            stillLayer.contents = nil
        case .still(let image):
            stillLayer.contents = image
            stillLayer.isHidden = image == nil
        }
        CATransaction.commit()
    }

    /// Fills these bounds, with implicit animations off.
    func layout(_ bounds: CGRect, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = bounds
        for sub in [stillLayer] + avSlots.map(\.layer) {
            sub.frame = CGRect(origin: .zero, size: bounds.size)
            sub.contentsScale = scale
        }
        CATransaction.commit()
    }

    func unload() {
        avSlots.forEach { $0.unload() }
    }
}
