import ExpoModulesCore
import UIKit

/// Shows one `MaskoPlayer` in a `MaskoPlayerView`. A new delivery, or
/// `getDelivery` given or taken away, loads a new player; the view going away
/// destroys it.
final class MaskoNativeView: ExpoView {
  let onPose = EventDispatcher()
  let onClip = EventDispatcher()
  let onReactionDone = EventDispatcher()
  let onMovement = EventDispatcher()
  let onError = EventDispatcher()
  let onDeliveryRequest = EventDispatcher()

  var delivery: String?
  var autoPlay: Bool?
  var sound = false
  var refreshes = false

  private(set) var player: MaskoPlayer?
  private let mascot = MaskoPlayerView()
  /// What the player was loaded with.
  private var loaded: (delivery: String, refreshes: Bool)?
  /// `getDelivery` calls waiting for JavaScript's answer.
  private var requests: [Int: CheckedContinuation<Data, Error>] = [:]
  private var lastRequest = 0

  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    addSubview(mascot)
  }

  deinit {
    for request in requests.values {
      request.resume(throwing: DeliveryUnavailable())
    }
    let player = self.player
    if Thread.isMainThread {
      MainActor.assumeIsolated { player?.destroy() }
    } else {
      Task { @MainActor in player?.destroy() }
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    mascot.frame = bounds
  }

  func propsChanged() {
    guard let delivery else { return unload() }
    if loaded?.delivery != delivery || loaded?.refreshes != refreshes {
      load(delivery)
    }
    player?.sound = sound
  }

  func position() -> [String: Any] {
    let position = player?.position()
    return ["clip": position?.clip.map { $0 as Any } ?? NSNull(), "time": position?.time ?? 0]
  }

  /// New links for the release that is playing: the player swaps them in.
  func updateDelivery(_ json: String) {
    player?.updateDelivery(Data(json.utf8))
  }

  func answerDelivery(_ request: Int, json: String?) {
    guard let continuation = requests.removeValue(forKey: request) else { return }
    if let json {
      continuation.resume(returning: Data(json.utf8))
    } else {
      continuation.resume(throwing: DeliveryUnavailable())
    }
  }

  private func load(_ json: String) {
    unload()
    var getDelivery: (@MainActor () async throws -> Data)?
    if refreshes {
      getDelivery = { [weak self] in
        guard let self else { throw DeliveryUnavailable() }
        return try await self.requestDelivery()
      }
    }
    let player = MaskoPlayer(delivery: Data(json.utf8), autoPlay: autoPlay, getDelivery: getDelivery)
    player.sound = sound
    player.onEvent = { [weak self] event in self?.send(event) }
    mascot.player = player
    self.player = player
    loaded = (json, refreshes)
  }

  private func unload() {
    for request in requests.values {
      request.resume(throwing: DeliveryUnavailable())
    }
    requests = [:]
    player?.destroy()
    player = nil
    mascot.player = nil
    loaded = nil
  }

  /// Asks JavaScript's `getDelivery` and waits for `answerDelivery`.
  private func requestDelivery() async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      lastRequest += 1
      requests[lastRequest] = continuation
      onDeliveryRequest(["request": lastRequest])
    }
  }

  private func send(_ event: MaskoPlayer.Event) {
    switch event {
    case let .pose(pose):
      onPose(["pose": pose])
    case let .clip(clip, kind, rate):
      onClip(["clip": clip, "kind": kind.rawValue, "rate": rate])
    case let .reactionDone(name, used):
      onReactionDone(["name": name, "used": used])
    case let .movement(edge, movement, rate, seconds):
      onMovement(["edge": edge, "movement": movement.plain, "rate": rate, "seconds": seconds])
    case let .error(code, detail):
      var payload: [String: Any] = ["code": code]
      payload["detail"] = detail
      onError(payload)
    }
  }
}

/// `getDelivery` gave nothing: the player reports `refresh_failed`.
private struct DeliveryUnavailable: Error {}

private extension MaskoJSON {
  /// The value as Foundation types, for JavaScript.
  var plain: Any {
    switch self {
    case .null: return NSNull()
    case let .bool(value): return value
    case let .number(value): return value
    case let .string(value): return value
    case let .array(values): return values.map(\.plain)
    case let .object(values): return values.mapValues(\.plain)
    }
  }
}
