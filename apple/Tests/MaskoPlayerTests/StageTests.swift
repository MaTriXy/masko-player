import AVFoundation
import XCTest

@testable import MaskoPlayer

/// The real stage's slots, and what the package ships with them.
@MainActor
final class StageTests: XCTestCase {
    let clip = Bundle.module.url(forResource: "Clips", withExtension: nil)!.appendingPathComponent("loop.mov")

    #if !os(visionOS)
    func testAMascotNeverKeepsTheScreenAwake() {
        let stage = AVStage()
        for slot in stage.clipSlots.map(\.hevc) {
            XCTAssertFalse(slot.player.preventsDisplaySleepDuringVideoPlayback)
        }
    }
    #endif

    func testASlotLetGoOfWithoutUnloadStopsPolling() throws {
        var slot: AVSlot? = AVSlot()
        slot?.load(clip) { _ in }
        let timer = try XCTUnwrap(slot?.watch.timer)
        XCTAssertTrue(timer.isValid)
        XCTAssertEqual(slot?.watch.observers.count, 2)
        weak var gone = slot
        slot = nil
        XCTAssertNil(gone)
        XCTAssertFalse(timer.isValid, "the run loop lets go of the timer")
    }

    func testThePackageShipsAPrivacyManifest() throws {
        // The resource bundle sits in the test bundle or beside it.
        let tests = Bundle(for: StageTests.self).bundleURL
        let bundle = [tests, tests.deletingLastPathComponent(), Bundle.main.bundleURL].lazy
            .compactMap { Bundle(url: $0.appendingPathComponent("MaskoPlayer_MaskoPlayer.bundle")) }
            .first
        let manifest = try XCTUnwrap(bundle?.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: manifest), format: nil) as? [String: Any])
        XCTAssertEqual(plist["NSPrivacyTracking"] as? Bool, false)
        let apis = try XCTUnwrap(plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        XCTAssertEqual(apis.count, 1)
        XCTAssertEqual(apis[0]["NSPrivacyAccessedAPIType"] as? String, "NSPrivacyAccessedAPICategorySystemBootTime")
        XCTAssertEqual(apis[0]["NSPrivacyAccessedAPITypeReasons"] as? [String], ["35F9.1"])
    }
}
