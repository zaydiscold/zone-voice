// by zayd/cold @ zayd.wtf

import Foundation
import OSLog

/// Per-keystroke cost accounting: how long the key's handler and the host's text-change callback
/// take, and how many document-context reads (IPC round trips to the host on a device) each makes.
/// Signposts show in Instruments Points of Interest; the summary line is logged per key in
/// Debug builds only. Counts and durations only, never characters.
@MainActor
enum KeyTrace {
    static let signposter = OSSignposter(subsystem: "wtf.zayd.zone", category: "PointsOfInterest")
    /// Document-context reads since launch; stages diff it.
    private(set) static var contextReads = 0

    static func countContextRead() {
        contextReads += 1
    }

    private static var touchCount = 0
    private static var touchDelaySum: Double = 0
    private static var touchDelayMax: Double = 0
    private static var slowTouches = 0

    /// UIKit's event timestamp uses system uptime. Aggregate only timing, never key identities
    /// or text; this includes dispatch delay that a post-release handler trace cannot see.
    static func touch(timestamp: TimeInterval, down: Bool) {
        guard down else { return }
        let delay = max(0, (ProcessInfo.processInfo.systemUptime - timestamp) * 1_000)
        touchCount += 1
        touchDelaySum += delay
        touchDelayMax = max(touchDelayMax, delay)
        if delay > 16.7 { slowTouches += 1 }
        if touchCount % 32 == 0 {
            signposter.emitEvent("touch-dispatch", "count=\(touchCount, privacy: .public) meanMs=\(touchDelaySum / Double(touchCount), privacy: .public) maxMs=\(touchDelayMax, privacy: .public) over16_7ms=\(slowTouches, privacy: .public)")
        }
    }

    /// Runs one stage of a keystroke inside a signpost interval and, in Debug, logs its time and reads.
    static func measure<T>(_ stage: StaticString, _ body: () -> T) -> T {
        let state = signposter.beginInterval(stage)
        #if DEBUG
        let reads = contextReads
        let start = DispatchTime.now().uptimeNanoseconds
        #endif
        let result = body()
        signposter.endInterval(stage, state)
        #if DEBUG
        let micros = (DispatchTime.now().uptimeNanoseconds - start) / 1_000
        KeyboardLog.typing.info("trace \(stage, privacy: .public): \(micros) us, \(contextReads - reads) context reads")
        #endif
        return result
    }
}
