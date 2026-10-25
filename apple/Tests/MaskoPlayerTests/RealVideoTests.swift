import AVFoundation
import XCTest

@testable import MaskoPlayer

/// The real stage, watched: every swap records whether the slot held a
/// decoded frame at that moment.
@MainActor
final class SpyStage: Stage {
    let real = AVStage()
    var slots: [VideoSlot] { real.slots }
    private(set) var swaps: [(slot: Int, frame: CVPixelBuffer?, layerReady: Bool)] = []

    func present(_ content: StageContent) {
        if case let .slot(i) = content {
            let slot = real.avSlots[i]
            swaps.append((i, slot.firstFrame, slot.layer.isReadyForDisplay))
        }
        real.present(content)
    }
}

/// Real HEVC-with-alpha clips on AVFoundation (player.md, test 3).
@MainActor
final class RealVideoTests: XCTestCase {
    let clips = Bundle.module.url(forResource: "Clips", withExtension: nil)!

    func delivery() -> Data {
        let loop = clips.appendingPathComponent("loop.mov").absoluteString
        let move = clips.appendingPathComponent("move.mov").absoluteString
        return Data(
            """
            {
              "deliverySchemaVersion": 1,
              "playerContract": 1,
              "requires": [],
              "target": "apple",
              "mode": "selected",
              "runtimeGraph": {
                "runtimeGraphSchemaVersion": 1,
                "version": "2.1",
                "name": "Real video",
                "initialNode": "idle",
                "autoPlay": true,
                "nodes": [{"id": "idle", "name": "Idle"}, {"id": "wave", "name": "Wave"}],
                "edges": [
                  {"id": "idle-loop", "source": "idle", "target": "idle", "isLoop": true, "duration": 0.5,
                   "videos": {"hevc": "\(loop)"}},
                  {"id": "wave-loop", "source": "wave", "target": "wave", "isLoop": true, "duration": 0.5,
                   "videos": {"hevc": "\(loop)"}},
                  {"id": "to-wave", "source": "idle", "target": "wave", "isLoop": false, "duration": 0.4,
                   "conditions": [{"input": "behavior::pointerHover"}], "videos": {"hevc": "\(move)"},
                   "movement": {"dx": 10}},
                  {"id": "wave-back", "source": "wave", "target": "idle", "isLoop": false, "duration": 0.4,
                   "conditions": [{"input": "behavior::pointerHover", "value": false}], "videos": {"hevc": "\(move)"}}
                ]
              }
            }
            """.utf8)
    }

    /// Alpha of one pixel of a BGRA frame.
    func alpha(_ frame: CVPixelBuffer, x: Int, y: Int) -> UInt8 {
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
        return base[y * CVPixelBufferGetBytesPerRow(frame) + x * 4 + 3]
    }

    func testTheFileCacheReadsALoneClipsLengthAndSoundTrack() async throws {
        let loop = clips.appendingPathComponent("loop.mov")
        let asset = AVURLAsset(url: loop)
        let expected = try await asset.load(.duration).seconds
        let voiced = try await !asset.loadTracks(withMediaType: .audio).isEmpty
        let cache = FileCache()
        let file: ClipFile? = await withCheckedContinuation { done in
            cache.clipFile(loop, key: "clip") { done.resume(returning: $0) }
        }
        XCTAssertEqual(try XCTUnwrap(file).seconds, expected, accuracy: 0.001)
        XCTAssertEqual(file?.voiced, voiced)
        XCTAssertGreaterThan(expected, 0)
        let missing: ClipFile? = await withCheckedContinuation { done in
            cache.clipFile(clips.appendingPathComponent("none.mov"), key: "missing") { done.resume(returning: $0) }
        }
        XCTAssertNil(missing)
    }

    func testTheClipFilesHaveAnAlphaChannel() async throws {
        let asset = AVURLAsset(url: clips.appendingPathComponent("loop.mov"))
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let formats = try await track.load(.formatDescriptions)
        let format = try XCTUnwrap(formats.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kCMVideoCodecType_HEVC)
        let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any]
        XCTAssertEqual(extensions?[kCMFormatDescriptionExtension_ContainsAlphaChannel as String] as? Bool, true)
    }

    func testRealClipsSwapOnADecodedFrameAndEndByTheirNotification() throws {
        let stage = SpyStage()
        let player = MaskoPlayer(
            delivery: delivery(), autoPlay: nil, stage: stage, loader: FileCache(), sounds: AVSounds(),
            host: .real)
        defer { player.destroy() }
        var log: [(event: String, at: Date)] = []
        var waiting: (String, Int, XCTestExpectation)?
        player.onEvent = { event in
            let text: String
            switch event {
            case let .pose(p): text = "pose:\(p)"
            case let .clip(c, _, _): text = "clip:\(c)"
            case let .reactionDone(n, _): text = "done:\(n)"
            case let .movement(e, _, _, _): text = "movement:\(e)"
            case let .error(code, _): text = "error:\(code)"
            }
            log.append((text, Date()))
            if let (want, count, expectation) = waiting, log.filter({ $0.event == want }).count >= count {
                waiting = nil
                expectation.fulfill()
            }
        }
        func wait(for event: String, count: Int = 1) {
            let e = expectation(description: "\(event) x\(count)")
            waiting = (event, count, e)
            self.wait(for: [e], timeout: 5)
        }

        // The first clip shows once a frame is decoded, then loops on the end
        // notification: no swap, and well before the safety net (1.5 s).
        player.boot()
        wait(for: "clip:idle-loop", count: 2)
        let shows = log.filter { $0.event == "clip:idle-loop" }.map(\.at)
        let loop = shows[1].timeIntervalSince(shows[0])
        XCTAssertGreaterThan(loop, 0.4)
        XCTAssertLessThan(loop, 1.2, "the end notification, not the safety net, ended the clip")
        XCTAssertEqual(stage.swaps.map(\.slot), [0], "a loop restarts in its slot")
        let first = try XCTUnwrap(stage.swaps[0].frame, "the swap waited for a decoded frame")
        XCTAssertEqual(alpha(first, x: 2, y: 2), 0, "transparent where the clip is transparent")
        XCTAssertEqual(alpha(first, x: 48, y: 48), 255, "opaque where the clip is opaque")

        // A person's move swaps to the other slot after its first frame.
        player.hover(true)
        wait(for: "clip:wave-loop")
        XCTAssertEqual(stage.swaps.map(\.slot), [0, 1, 0])
        XCTAssertEqual(
            log.map(\.event).filter { !$0.hasPrefix("clip:idle-loop") },
            ["pose:idle", "clip:to-wave", "movement:to-wave", "pose:wave", "clip:wave-loop"])

        // The way back waits for the loop's end, loaded ahead in the hidden
        // slot, and swaps in on a decoded frame too.
        player.hover(false)
        XCTAssertEqual(player.engine?.state().nextClip, "wave-back")
        wait(for: "clip:idle-loop", count: 3)
        XCTAssertEqual(stage.swaps.map(\.slot), [0, 1, 0, 1, 0])
        XCTAssertTrue(stage.swaps.allSatisfy { $0.frame != nil }, "every swap had a decoded frame")
        #if os(macOS)
        // On iOS a layer outside any window may never say so; the slot then
        // swaps a moment after the decoded frame.
        XCTAssertTrue(stage.swaps.allSatisfy(\.layerReady), "and its layer had it ready for display")
        #endif
        XCTAssertFalse(log.contains { $0.event.hasPrefix("error:") }, "\(log.map(\.event))")
        let position = player.position()
        XCTAssertEqual(position.clip, "idle-loop")
        XCTAssertLessThanOrEqual(position.time, 0.5)
    }
}
