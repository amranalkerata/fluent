import Foundation
import os

/// Stage timings of the shortcut → record → transcribe → paste cycle, kept in Release at
/// `.info` level (not persisted unless streamed, so it costs next to nothing):
///
///     log stream --predicate 'subsystem == "com.fluent.app"' --info
///
/// Only stage names, engine names and numbers are logged. Never pass transcript text here.
enum LatencyLog {
    static let logger = Logger(subsystem: "com.fluent.app", category: "timing")

    /// Monotonic time in nanoseconds (not affected by clock changes).
    static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    /// Milliseconds elapsed since `start` (a value from `now()`).
    static func ms(since start: UInt64) -> Double {
        Double(now() &- start) / 1_000_000
    }

    /// Logs `stage` with the milliseconds elapsed since `start` and returns them.
    @discardableResult
    static func log(_ stage: String, since start: UInt64) -> Double {
        let elapsed = ms(since: start)
        log(stage, ms: elapsed)
        return elapsed
    }

    static func log(_ stage: String, ms: Double) {
        logger.info("\(stage, privacy: .public) \(ms, format: .fixed(precision: 1), privacy: .public) ms")
    }

    static func log(_ stage: String, count: Int) {
        logger.info("\(stage, privacy: .public) \(count, privacy: .public)")
    }

    static func log(_ stage: String, ms: Double, engine: String) {
        logger.info("\(stage, privacy: .public) \(ms, format: .fixed(precision: 1), privacy: .public) ms engine=\(engine, privacy: .public)")
    }
}
