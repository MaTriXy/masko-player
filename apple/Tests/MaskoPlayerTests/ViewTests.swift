import XCTest

@testable import MaskoPlayer

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The view hosts the real stage and turns the person's input into values
/// (rules.md 3.5).
@MainActor
final class ViewTests: XCTestCase {
    func delivery() -> Data {
        Data(PlayerTests.deliveryText.utf8)
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
        XCTAssertEqual(stage.avSlots[0].layer.frame.size, CGSize(width: 120, height: 80))
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
    func event(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func testClicksKeysAndThePointerBecomeValues() {
        let host = FakeHost()
        let stage = FakeStage()
        let player = MaskoPlayer(
            delivery: delivery(), autoPlay: nil, stage: stage, loader: FakeLoader(), sounds: FakeSounds(),
            host: host.host)
        player.boot()
        stage.fakeSlots[0].decodeFirstFrame()
        let view = MaskoPlayerView(player: player)
        view.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let engine = player.engine!

        view.mouseEntered(with: event(.mouseMoved, x: 50, y: 50))
        XCTAssertEqual(engine.value(name: "pointerHover"), .bool(value: true))
        view.mouseExited(with: event(.mouseMoved, x: 150, y: 50))
        XCTAssertEqual(engine.value(name: "pointerHover"), .bool(value: false))

        view.mouseDown(with: event(.leftMouseDown, x: 50, y: 50))
        view.mouseUp(with: event(.leftMouseUp, x: 51, y: 50))
        XCTAssertEqual(engine.pendingFires(), ["action::click"])

        // A press that moves is a drag, not a click.
        player.reset()
        view.mouseDown(with: event(.leftMouseDown, x: 50, y: 50))
        view.mouseUp(with: event(.leftMouseUp, x: 70, y: 50))
        XCTAssertEqual(engine.pendingFires(), [])

        let space = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49)!
        view.keyDown(with: space)
        XCTAssertEqual(engine.pendingFires(), ["action::click"])
    }
    #endif

    #if canImport(UIKit)
    func testActivatingTheViewClicks() {
        let player = MaskoPlayer(
            delivery: delivery(), autoPlay: nil, stage: FakeStage(), loader: FakeLoader(), sounds: FakeSounds(),
            host: FakeHost().host)
        player.boot()
        let view = MaskoPlayerView(player: player)
        XCTAssertTrue(view.accessibilityActivate())
        XCTAssertEqual(player.engine!.pendingFires(), ["action::click"])
    }
    #endif
}
