import XCTest

@testable import MaskoPlayer

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The view hosts the real stage and leaves the person to the app
/// (rules.md 3.5).
@MainActor
final class ViewTests: XCTestCase {
    func delivery() -> Data {
        Data(PlayerTests.deliveryText.utf8)
    }

    func makePlayer(_ host: FakeHost? = nil, stage: Stage? = nil) -> MaskoPlayer {
        MaskoPlayer(
            delivery: delivery(), autoPlay: nil, stage: stage ?? AVStage(), loader: FakeLoader(),
            sounds: FakeSounds(), host: (host ?? FakeHost()).host)
    }

    #if canImport(UIKit)
    lazy var window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))

    func show(_ view: MaskoPlayerView, size: CGFloat) {
        view.frame = CGRect(x: 0, y: 0, width: size, height: size)
        window.addSubview(view)
        view.layoutSubviews()
    }

    func layer(_ view: MaskoPlayerView) -> CALayer { view.layer }
    #else
    lazy var window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.titled], backing: .buffered,
        defer: true)

    func show(_ view: MaskoPlayerView, size: CGFloat) {
        view.frame = CGRect(x: 0, y: 0, width: size, height: size)
        window.contentView!.addSubview(view)
        view.layout()
    }

    func layer(_ view: MaskoPlayerView) -> CALayer { view.layer! }
    #endif

    func testOnePlayerInTwoViewsShowsInTheNewestOnScreen() {
        let player = makePlayer()
        let stage = player.stage as! AVStage
        let first = MaskoPlayerView(player: player)
        show(first, size: 100)
        XCTAssertTrue(stage.layer.superlayer === layer(first))
        XCTAssertFalse(player.hostPaused)

        // SwiftUI makes the new view before it takes the old one away.
        let second = MaskoPlayerView(player: player)
        show(second, size: 50)
        XCTAssertTrue(stage.layer.superlayer === layer(second))
        XCTAssertEqual(stage.layer.frame.size, CGSize(width: 50, height: 50))
        first.removeFromSuperview()
        XCTAssertTrue(stage.layer.superlayer === layer(second), "the old view going away takes nothing")
        XCTAssertFalse(player.hostPaused, "and the mascot plays on")
        // A layout of the view that does not show the stage leaves it alone.
        show(first, size: 100)
        XCTAssertTrue(stage.layer.superlayer === layer(second))
        XCTAssertEqual(stage.layer.frame.size, CGSize(width: 50, height: 50))

        // The newer view goes away: the stage comes back to the one still there.
        second.removeFromSuperview()
        XCTAssertTrue(stage.layer.superlayer === layer(first))
        XCTAssertEqual(stage.layer.frame.size, CGSize(width: 100, height: 100))
        XCTAssertFalse(player.hostPaused)
        first.removeFromSuperview()
        XCTAssertTrue(player.hostPaused, "no view on screen: the player pauses itself")
    }

    func testAPlayerTheViewLetsGoOfStopsRunning() {
        let host = FakeHost()
        let stage = FakeStage()
        let old = makePlayer(host, stage: stage)
        old.boot()
        stage.fakeSlots[0].decodeFirstFrame()
        let view = MaskoPlayerView(player: old)
        show(view, size: 100)
        host.advance(1)
        XCTAssertEqual(old.now, 1000)
        let new = makePlayer()
        view.player = new
        XCTAssertTrue(old.hostPaused)
        XCTAssertEqual(stage.fakeSlots[0].log.last, "pause")
        host.advance(1)
        XCTAssertEqual(old.now, 1000, "its play time stopped with it")
        XCTAssertFalse(new.hostPaused)
        XCTAssertTrue((new.stage as! AVStage).layer.superlayer === layer(view))
    }

    func testTheViewHostsTheStageAndReportsItsSizeInPixels() {
        let player = MaskoPlayer(
            delivery: delivery(), autoPlay: false, stage: AVStage(), loader: FakeLoader(), sounds: FakeSounds(),
            host: FakeHost().host)
        let view = MaskoPlayerView(player: player)
        view.frame = CGRect(x: 0, y: 0, width: 120, height: 80)
        #if canImport(UIKit)
        view.layoutSubviews()
        let scale = UIScreen.main.scale
        let host = view.layer
        #else
        view.layout()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let host = view.layer!
        #endif
        let stage = player.stage as! AVStage
        XCTAssertTrue(stage.layer.superlayer === host)
        XCTAssertEqual(stage.layer.frame.size, CGSize(width: 120, height: 80))
        XCTAssertEqual(stage.clipSlots[0].layer.frame.size, CGSize(width: 120, height: 80))
        XCTAssertEqual(stage.clipSlots[0].av1.layer.frame.size, CGSize(width: 120, height: 80))
        XCTAssertEqual(player.displayPixels, Double(120 * scale))

        // Another player takes the view's place.
        let other = MaskoPlayer(
            delivery: delivery(), autoPlay: false, stage: AVStage(), loader: FakeLoader(), sounds: FakeSounds(),
            host: FakeHost().host)
        view.player = other
        XCTAssertNil(stage.layer.superlayer)
        XCTAssertTrue((other.stage as! AVStage).layer.superlayer === host)
    }

    #if canImport(AppKit) && !canImport(UIKit)
    func testTheViewDoesNotWatchThePerson() {
        let stage = FakeStage()
        let player = makePlayer(stage: stage)
        player.boot()
        stage.fakeSlots[0].decodeFirstFrame()
        let view = MaskoPlayerView(player: player)
        show(view, size: 100)
        XCTAssertTrue(view.trackingAreas.isEmpty)
        XCTAssertFalse(view.acceptsFirstResponder)
        XCTAssertEqual(player.engine!.value(name: "pointerHover"), .bool(value: false))
        XCTAssertEqual(player.engine!.pendingFires(), [])
    }
    #endif

    #if canImport(UIKit)
    func testTheViewDoesNotWatchThePerson() {
        let player = MaskoPlayer(
            delivery: delivery(), autoPlay: nil, stage: FakeStage(), loader: FakeLoader(), sounds: FakeSounds(),
            host: FakeHost().host)
        player.boot()
        let view = MaskoPlayerView(player: player)
        XCTAssertTrue(view.gestureRecognizers?.isEmpty ?? true)
        XCTAssertFalse(view.accessibilityActivate())
        XCTAssertEqual(player.engine!.pendingFires(), [])
    }
    #endif

    func testTheAppSendsThePersonWithItsFullNames() {
        let stage = FakeStage()
        let player = makePlayer(stage: stage)
        player.boot()
        stage.fakeSlots[0].decodeFirstFrame()
        player.set("behavior::pointerHover", true)
        XCTAssertEqual(player.engine!.value(name: "pointerHover"), .bool(value: true))
        XCTAssertEqual(player.engine!.state().nextClip, "wave", "it waits for the end of the loop")
    }
}
