import QuartzCore

/// A view that shows a player's stage: `MaskoPlayerView`.
@MainActor
protocol StageHost: AnyObject {
    /// The layer the stage goes in.
    var stageSuperlayer: CALayer? { get }
    /// In a window, and on iPhone and iPad with the app in the foreground.
    var isShowing: Bool { get }
    var stageBounds: CGRect { get }
    /// Pixels per point on its screen.
    var stageScale: CGFloat { get }
}

/// The views a player is given, oldest first. A layer is in one place at a
/// time, so the stage shows in one of them: the newest on screen, else the
/// newest. Play pauses while that view is off screen, or when no view is
/// left.
@MainActor
struct StageHosts {
    private struct Weak {
        weak var view: StageHost?
    }

    private var views: [Weak] = []

    mutating func add(_ view: StageHost) {
        remove(view)
        views.append(Weak(view: view))
    }

    mutating func remove(_ view: StageHost) {
        views.removeAll { $0.view == nil || $0.view === view }
    }

    var current: StageHost? {
        let live = views.compactMap(\.view)
        return live.last(where: \.isShowing) ?? live.last
    }
}

extension MaskoPlayer {
    func addHost(_ view: StageHost) {
        hosts.add(view)
        updateHost()
    }

    func removeHost(_ view: StageHost) {
        hosts.remove(view)
        updateHost()
    }

    /// Puts the stage in the view it belongs in and lays it out there, then
    /// pauses or resumes play as that view is on screen or not. A view calls
    /// it whenever it changes window, size or foreground.
    func updateHost() {
        let host = hosts.current
        if let stage = stage as? AVStage {
            if let host, let superlayer = host.stageSuperlayer {
                if stage.layer.superlayer !== superlayer {
                    superlayer.addSublayer(stage.layer)
                }
                let bounds = host.stageBounds
                let scale = host.stageScale
                stage.layout(bounds, scale: scale)
                // Before layout there is no size yet: the base file plays,
                // and the next loop picks again.
                if bounds.width > 0, bounds.height > 0, scale > 0 {
                    displayPixels = Double(max(bounds.width, bounds.height) * scale)
                }
            } else {
                stage.layer.removeFromSuperlayer()
            }
        }
        setHostActive(host?.isShowing ?? false)
    }
}

#if canImport(UIKit)
import UIKit

/// Shows a `MaskoPlayer` and turns the person's taps and pointer into its
/// values (rules.md 3.5): a tap, or Return or Space while focused, fires
/// `click`; an iPad pointer over the mascot sets `pointerHover`. Out of its
/// window or with the app in the background, the player pauses itself.
///
/// A player shows in one view at a time: the newest view given it that is
/// in a window. A player the view lets go of pauses unless another view
/// shows it.
public final class MaskoPlayerView: UIView, StageHost {
    public var player: MaskoPlayer? {
        didSet {
            guard player !== oldValue else { return }
            if hovering { oldValue?.hover(false) }
            hovering = false
            oldValue?.removeHost(self)
            player?.addHost(self)
            setNeedsLayout()
        }
    }

    private var hovering = false
    private var backgrounded = false

    public init(player: MaskoPlayer? = nil) {
        super.init(frame: .zero)
        setUp()
        self.player = player
        player?.addHost(self)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = .image
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(wentToBackground), name: UIApplication.didEnterBackgroundNotification,
            object: nil)
        center.addObserver(
            self, selector: #selector(cameToForeground), name: UIApplication.willEnterForegroundNotification,
            object: nil)
    }

    var stageSuperlayer: CALayer? { layer }
    var isShowing: Bool { window != nil && !backgrounded }
    var stageBounds: CGRect { bounds }
    var stageScale: CGFloat {
        #if os(visionOS)
        traitCollection.displayScale
        #else
        window?.screen.scale ?? UIScreen.main.scale
        #endif
    }

    public override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        // The pointer cannot stay over a view that leaves its window.
        if hovering {
            hovering = false
            player?.hover(false)
        }
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        player?.updateHost()
    }

    @objc private func wentToBackground() {
        backgrounded = true
        player?.updateHost()
    }

    @objc private func cameToForeground() {
        backgrounded = false
        player?.updateHost()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        player?.updateHost()
    }

    @objc private func tapped() {
        player?.click()
    }

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            if !hovering {
                hovering = true
                player?.hover(true)
            }
        default:
            if hovering {
                hovering = false
                player?.hover(false)
            }
        }
    }

    public override var canBecomeFocused: Bool { true }

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let keys = presses.compactMap { $0.key?.keyCode }
        if keys.contains(.keyboardReturnOrEnter) || keys.contains(.keyboardSpacebar) {
            player?.click()
        } else {
            super.pressesBegan(presses, with: event)
        }
    }

    public override func accessibilityActivate() -> Bool {
        player?.click()
        return true
    }
}

#elseif canImport(AppKit)
import AppKit

/// Shows a `MaskoPlayer` and turns the person's clicks and pointer into its
/// values (rules.md 3.5): a click, or Return or Space while focused, fires
/// `click`; the pointer over the mascot sets `pointerHover`. Out of its
/// window, the player pauses itself.
///
/// A player shows in one view at a time: the newest view given it that is
/// in a window. A player the view lets go of pauses unless another view
/// shows it.
public final class MaskoPlayerView: NSView, StageHost {
    public var player: MaskoPlayer? {
        didSet {
            guard player !== oldValue else { return }
            if hovering { oldValue?.hover(false) }
            hovering = false
            oldValue?.removeHost(self)
            player?.addHost(self)
            needsLayout = true
        }
    }

    private var hovering = false
    private var tracking: NSTrackingArea?
    private var downAt: NSPoint?
    /// A press that moves further than this is a drag, not a click.
    private let clickSlop: CGFloat = 4

    public init(player: MaskoPlayer? = nil) {
        super.init(frame: .zero)
        setUp()
        self.player = player
        player?.addHost(self)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        wantsLayer = true
        layer?.backgroundColor = .clear
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    var stageSuperlayer: CALayer? { layer }
    var isShowing: Bool { window != nil }
    var stageBounds: CGRect { bounds }
    var stageScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // A view that leaves its window gets no mouseExited: the pointer is
        // no longer over it.
        if hovering {
            hovering = false
            player?.hover(false)
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        player?.updateHost()
    }

    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        player?.updateHost()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    public override func mouseEntered(with event: NSEvent) {
        if !hovering {
            hovering = true
            player?.hover(true)
        }
    }

    public override func mouseExited(with event: NSEvent) {
        if hovering {
            hovering = false
            player?.hover(false)
        }
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func mouseDown(with event: NSEvent) {
        downAt = event.locationInWindow
    }

    public override func mouseUp(with event: NSEvent) {
        defer { downAt = nil }
        guard let downAt else { return }
        let up = event.locationInWindow
        let inside = bounds.contains(convert(up, from: nil))
        if inside, hypot(up.x - downAt.x, up.y - downAt.y) <= clickSlop {
            player?.click()
        }
    }

    public override var acceptsFirstResponder: Bool { true }

    public override func keyDown(with event: NSEvent) {
        // Return, keypad Enter, Space.
        if [36, 76, 49].contains(event.keyCode) {
            player?.click()
        } else {
            super.keyDown(with: event)
        }
    }

    public override func accessibilityPerformPress() -> Bool {
        player?.click()
        return true
    }
}
#endif
