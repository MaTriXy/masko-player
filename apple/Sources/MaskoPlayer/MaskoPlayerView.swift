import QuartzCore

#if canImport(UIKit)
import UIKit

/// Shows a `MaskoPlayer` and turns the person's taps and pointer into its
/// values (rules.md 3.5): a tap, or Return or Space while focused, fires
/// `click`; an iPad pointer over the mascot sets `pointerHover`. Out of its
/// window or with the app in the background, the player pauses itself.
public final class MaskoPlayerView: UIView {
    public var player: MaskoPlayer? {
        didSet {
            guard player !== oldValue else { return }
            if hovering { oldValue?.hover(false) }
            hovering = false
            attach()
        }
    }

    private var hosted: CALayer?
    private var hovering = false
    private var backgrounded = false

    public init(player: MaskoPlayer? = nil) {
        super.init(frame: .zero)
        setUp()
        self.player = player
        attach()
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

    private func attach() {
        hosted?.removeFromSuperlayer()
        hosted = (player?.stage as? AVStage)?.layer
        if let hosted {
            layer.addSublayer(hosted)
        }
        if window != nil { updateHost() }
        setNeedsLayout()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        updateHost()
    }

    @objc private func wentToBackground() {
        backgrounded = true
        if window != nil { updateHost() }
    }

    @objc private func cameToForeground() {
        backgrounded = false
        if window != nil { updateHost() }
    }

    private func updateHost() {
        player?.setHostActive(window != nil && !backgrounded)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? UIScreen.main.scale
        (player?.stage as? AVStage)?.layout(bounds, scale: scale)
        player?.displayPixels = Double(max(bounds.width, bounds.height) * scale)
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
public final class MaskoPlayerView: NSView {
    public var player: MaskoPlayer? {
        didSet {
            guard player !== oldValue else { return }
            if hovering { oldValue?.hover(false) }
            hovering = false
            attach()
        }
    }

    private var hosted: CALayer?
    private var hovering = false
    private var tracking: NSTrackingArea?
    private var downAt: NSPoint?
    /// A press that moves further than this is a drag, not a click.
    private let clickSlop: CGFloat = 4

    public init(player: MaskoPlayer? = nil) {
        super.init(frame: .zero)
        setUp()
        self.player = player
        attach()
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

    private func attach() {
        hosted?.removeFromSuperlayer()
        hosted = (player?.stage as? AVStage)?.layer
        if let hosted {
            layer?.addSublayer(hosted)
        }
        if window != nil { player?.setHostActive(true) }
        needsLayout = true
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        player?.setHostActive(window != nil)
    }

    public override var isFlipped: Bool { true }

    public override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        (player?.stage as? AVStage)?.layout(bounds, scale: scale)
        player?.displayPixels = Double(max(bounds.width, bounds.height) * scale)
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
