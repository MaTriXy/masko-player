import Foundation

/// Play time (player.md, "The clock"): 0 when the mascot starts, moving with
/// real time, stopped while the player is paused.
struct PlayClock {
    /// Play time banked before the current run, in seconds.
    private var banked: TimeInterval = 0
    /// The uptime at which the current run began, while running.
    private var since: TimeInterval?

    func seconds(at uptime: TimeInterval) -> TimeInterval {
        banked + (since.map { max(uptime - $0, 0) } ?? 0)
    }

    /// Whole milliseconds, as every engine call takes them.
    func milliseconds(at uptime: TimeInterval) -> UInt64 {
        UInt64((seconds(at: uptime) * 1000).rounded(.down))
    }

    mutating func run(at uptime: TimeInterval) {
        if since == nil {
            since = uptime
        }
    }

    mutating func stop(at uptime: TimeInterval) {
        banked = seconds(at: uptime)
        since = nil
    }
}

/// A scheduled action that can be called off.
final class Cancellation {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    func cancel() {
        action()
    }
}

/// Time and timers, so tests can drive the player with a fake clock.
struct PlayerHost {
    /// Seconds on a clock that never jumps.
    var uptime: @MainActor () -> TimeInterval
    /// The wall clock, for signed-link expiry.
    var date: @MainActor () -> Date
    /// Runs `action` on the main actor after `delay` seconds of uptime.
    var after: @MainActor (_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Cancellation
    /// Runs `action` on the main actor at this wall-clock date, even when
    /// the device slept in between.
    var at: @MainActor (_ date: Date, _ action: @escaping @MainActor () -> Void) -> Cancellation

    static var real: PlayerHost {
        PlayerHost(
            uptime: { ProcessInfo.processInfo.systemUptime },
            date: { Date() },
            after: { delay, action in
                let item = DispatchWorkItem {
                    MainActor.assumeIsolated { action() }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0), execute: item)
                return Cancellation { item.cancel() }
            },
            at: { date, action in
                let item = DispatchWorkItem {
                    MainActor.assumeIsolated { action() }
                }
                let delay = max(date.timeIntervalSinceNow, 0)
                DispatchQueue.main.asyncAfter(wallDeadline: .now() + delay, execute: item)
                return Cancellation { item.cancel() }
            }
        )
    }
}
