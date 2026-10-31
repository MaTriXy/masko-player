import Flutter
import XCTest

@testable import masko_player

class RunnerTests: XCTestCase {
  /// `maskoFormats()` asks the plugin, which answers the Swift player's formats.
  func testFormats() {
    let plugin = MaskoPlayerPlugin()
    let answered = expectation(description: "the plugin answers")
    plugin.handle(FlutterMethodCall(methodName: "formats", arguments: nil)) { result in
      XCTAssertEqual(result as? String, "av1")
      answered.fulfill()
    }
    waitForExpectations(timeout: 1)
  }
}
