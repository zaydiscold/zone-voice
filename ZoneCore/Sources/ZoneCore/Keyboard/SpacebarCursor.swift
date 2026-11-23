// by zayd/cold @ zayd.wtf

import Foundation

/// One touch event's worth of cursor travel: characters along the text, and lines up (negative)
/// or down (positive).
public struct CursorMotion: Equatable {
    public var steps: Int
    public var lines: Int
    public init(steps: Int = 0, lines: Int = 0) { self.steps = steps; self.lines = lines }
}

/// Hold still, or slide sideways along space, then scrub. A hold activates after
/// `holdDuration`; a clearly horizontal slide past `slideActivation` activates at once, so a
/// slide on space never ends as a typed space. Vertical travel before activation disarms it,
/// leaving the grid's ordinary release tolerance.
///
/// Once active the space bar is a small trackpad. Sideways travel moves by characters and a
/// fast drag covers more of them per point, as on Apple's keyboard. Up and down move by lines,
/// and a diagonal does both. Three things keep it steady under a real thumb:
/// - Touch samples wobble by a fraction of a point. Travel against the drag only counts as a
///   reversal once it passes `reversalSlop`, so wobble never throws away banked travel, and a
///   real reversal starts stepping at once without repaying it.
/// - Speed is smoothed over time, not over events, so 60 Hz and 120 Hz phones accelerate
///   alike, and a rest forgets the speed of the flick before it.
/// - A thumb pivots, so a sideways scrub drifts up and down. Lines only follow travel at least
///   as steep as `lineSlope`, and the first line needs `firstLineTravel`. After that the lane
///   is open and lines follow the finger both ways, until a sideways scrub closes it again.
public struct SpacebarCursorGesture {
    public static let holdDuration: TimeInterval = 0.35
    public static let holdSlop: Double = 10
    public static let slideActivation: Double = 16
    /// Points per character at a slow, precise speed, and the floor a fast flick reaches.
    public static let pointsPerStep: Double = 8
    public static let fastPointsPerStep: Double = 4
    /// Below `slowSpeed` points per second movement is precise; at `fastSpeed` it is fastest.
    public static let slowSpeed: Double = 150
    public static let fastSpeed: Double = 1100
    /// How quickly the measured speed follows the finger.
    public static let speedSmoothing: TimeInterval = 0.03
    /// Touch events arrive every frame while the finger moves. A gap longer than this is a
    /// rest, and the speed from before it fades.
    public static let restGap: TimeInterval = 0.02
    /// Points against the drag that are still touch noise, not a change of direction.
    public static let reversalSlop: Double = 2
    /// Characters a single touch event may move. At 120 events a second this is still over a
    /// thousand characters a second, without the caret jumping a visible distance at once.
    public static let maximumStepsPerEvent = 12
    public static let maximumSteps = 32
    public static let maximumLinesPerEvent = 6
    /// Travel that opens the up/down lane, and the travel for each line after that: about one
    /// line of body text, so the caret keeps pace with the finger.
    public static let firstLineTravel: Double = 24
    public static let pointsPerLine: Double = 20
    /// Vertical travel counts when the finger's recent path rises at least this steeply. A
    /// thumb's arc along the space bar stays under it.
    public static let lineSlope: Double = 0.6
    /// With the lane open, a path within this much sideways drift of vertical moves lines only,
    /// so the caret keeps its column as it climbs.
    public static let columnSlope: Double = 0.4
    /// Points of recent path the direction is read from.
    public static let trendLength: Double = 6
    /// Sideways travel that closes the lane.
    public static let laneExit: Double = 16

    public private(set) var isActive = false
    public private(set) var canActivate = true
    private let originX: Double
    private let originY: Double
    private var lastX: Double
    private var lastY: Double
    private var lastTime: TimeInterval?
    private var velocity: Double = 0
    private var characters = Travel()
    private var lines = Travel()
    private var trendX: Double = 0
    private var trendY: Double = 0
    private var laneOpen = false
    private var lanePending: Double = 0
    private var laneSideways: Double = 0

    public init(x: Double, y: Double) {
        originX = x; originY = y; lastX = x; lastY = y
    }

    public mutating func activate() -> Bool {
        guard canActivate, !isActive else { return false }
        isActive = true
        return true
    }

    /// Character steps only, for callers without a vertical lane.
    public mutating func move(x: Double, y: Double, time: TimeInterval? = nil) -> Int {
        motion(x: x, y: y, time: time).steps
    }

    /// Travel for the finger now at (`x`, `y`). Pass the touch's `time` to enable acceleration;
    /// without it every point counts at the precise rate.
    public mutating func motion(x: Double, y: Double, time: TimeInterval? = nil) -> CursorMotion {
        guard x.isFinite, y.isFinite else { return CursorMotion() }
        let elapsed: TimeInterval? = if let time, let lastTime, time > lastTime { time - lastTime } else { nil }
        defer { lastX = x; lastY = y; if let time { lastTime = time } }
        guard isActive else {
            guard canActivate else { return CursorMotion() }
            let dx = abs(x - originX), dy = abs(y - originY)
            if dx >= Self.slideActivation, dx >= 2 * dy {
                // Start from here: the activation travel itself does not move the caret.
                isActive = true
            } else if hypot(dx, dy) > Self.holdSlop, dy > dx / 2 {
                canActivate = false
            }
            return CursorMotion()
        }
        let dx = x - lastX, dy = y - lastY
        // The direction of the last few points of path. Signed, so wobble cancels out.
        let keep = exp(-hypot(dx, dy) / Self.trendLength)
        trendX = trendX * keep + dx
        trendY = trendY * keep + dy
        let sideways = abs(trendY) < Self.lineSlope * abs(trendX)
        let moved = vertical(dy, sideways: sideways, drift: abs(dx))
        let upright = laneOpen && abs(trendX) < Self.columnSlope * abs(trendY)
        return CursorMotion(steps: horizontal(upright ? 0 : dx, elapsed: elapsed), lines: moved)
    }

    private mutating func horizontal(_ delta: Double, elapsed: TimeInterval?) -> Int {
        // This event moves at the speed measured before it, then updates it: a lone spike moves
        // at the precise rate, and only speed sustained over several events accelerates.
        if let elapsed {
            velocity *= exp(-max(0, elapsed - Self.restGap) / Self.speedSmoothing)
        }
        let fast = min(1, max(0, (abs(velocity) - Self.slowSpeed) / (Self.fastSpeed - Self.slowSpeed)))
        if let elapsed {
            let instant = delta / max(elapsed, 1.0 / 240)
            velocity += (instant - velocity) * (1 - exp(-elapsed / Self.speedSmoothing))
        }
        characters.add(delta, per: Self.pointsPerStep - fast * (Self.pointsPerStep - Self.fastPointsPerStep))
        return characters.take(limit: Self.maximumStepsPerEvent)
    }

    private mutating func vertical(_ dy: Double, sideways: Bool, drift: Double) -> Int {
        if sideways {
            // A scrub along the bar: its drift is the thumb's arc, and enough of it closes the lane.
            if laneOpen {
                laneSideways += drift
                if laneSideways >= Self.laneExit { laneOpen = false; lines = Travel() }
            } else {
                lanePending *= exp(-drift / Self.laneExit)
            }
            return 0
        }
        laneSideways = 0
        guard laneOpen else {
            lanePending += dy
            guard abs(lanePending) >= Self.firstLineTravel else { return 0 }
            let first = lanePending < 0 ? -1 : 1
            laneOpen = true
            lines = Travel()
            lines.add(lanePending - Double(first) * Self.firstLineTravel, per: Self.pointsPerLine, heading: first)
            lanePending = 0
            return first + lines.take(limit: Self.maximumLinesPerEvent - 1)
        }
        lines.add(dy, per: Self.pointsPerLine)
        return lines.take(limit: Self.maximumLinesPerEvent)
    }

    /// Travel along one axis, counted in whole units (characters or lines).
    private struct Travel {
        /// Units banked toward the next whole one, signed.
        private var remainder: Double = 0
        private var direction = 0
        /// Points moved against `direction` and not yet taken back.
        private var against: Double = 0

        mutating func add(_ delta: Double, per unit: Double, heading: Int? = nil) {
            if let heading { direction = heading }
            guard delta != 0 else { return }
            let sign = delta < 0 ? -1 : 1
            if direction == 0 { direction = sign }
            if sign != direction {
                against += abs(delta)
                if against > SpacebarCursorGesture.reversalSlop {
                    // A real reversal: fine corrections begin at once, from the turning point,
                    // without first repaying the travel banked the other way.
                    direction = sign
                    remainder = Double(sign) * against / unit
                    against = 0
                    return
                }
            } else {
                against = max(0, against - abs(delta))
            }
            remainder += delta / unit
        }

        /// Whole units to move now. Travel beyond `limit` is dropped, not banked: a flick must
        /// not keep moving afterwards.
        mutating func take(limit: Int) -> Int {
            // The nudge keeps ten steps of a tenth from summing to just under one.
            let whole = (remainder + (remainder < 0 ? -1e-9 : 1e-9)).rounded(.towardZero)
            let cap = Double(limit)
            let taken = min(cap, max(-cap, whole))
            remainder = abs(whole) > cap ? 0 : remainder - taken
            return Int(taken)
        }
    }
}

/// Line breaks resist the caret: crossing one takes `extraSteps` more steps in the same
/// direction, so a fast drag stops at the end of a line instead of flying through blank lines,
/// and a deliberate push carries on to the next.
public struct CursorLineDetent {
    public static let extraSteps = 2
    private var held = 0
    private var direction = 0

    public init() {}

    /// Characters to actually move for `steps`, walking `side` (the text before the caret when
    /// moving back, after it when moving forward), and how many line breaks were crossed.
    /// Unknown context (nil) moves the plain step count.
    public mutating func walk(_ steps: Int, through side: String?) -> (characters: Int, breaks: Int) {
        guard steps != 0 else { return (0, 0) }
        let sign = steps < 0 ? -1 : 1
        if sign != direction { held = 0; direction = sign }
        guard let side else { return (steps, 0) }
        let characters = sign < 0 ? Array(side.reversed()) : Array(side)
        var remaining = abs(steps), moved = 0, breaks = 0
        while remaining > 0, moved < characters.count {
            remaining -= 1
            if characters[moved].isNewline {
                if held < Self.extraSteps { held += 1; continue }
                held = 0
                breaks += 1
            }
            moved += 1
        }
        return (sign * moved, breaks)
    }

    /// A vertical move or a pause in direction starts the resistance over.
    public mutating func reset() { held = 0; direction = 0 }
}

/// Up and down by lines. A keyboard cannot see the host's layout, so line breaks are exact and
/// soft wraps inside a paragraph are estimated as `wrapWidth` characters per line. The column
/// is kept across repeated moves (`goalColumn`), as editors do.
public enum CursorLines {
    /// Characters per wrapped line for a host about as wide as the keyboard: body text averages
    /// roughly 8.5 points a character (Notes is wider, T3 and Mail narrower). An estimate.
    public static func estimatedWrapWidth(points: Double) -> Int {
        guard points.isFinite, points > 0 else { return 40 }
        return max(20, Int(points / 8.5))
    }

    /// One line of movement. `move` is exact. `hop` crosses into a neighbouring paragraph the
    /// context did not show (real UIKit reports only the current paragraph): move that far, read
    /// the newly visible paragraph, then place the column with `columnFix`.
    public enum Step: Equatable { case move(Int), hop(Int), none }

    public static func step(_ direction: Int, goalColumn: Int, before: String?, after: String?,
                            wrapWidth: Int) -> Step {
        let width = max(8, wrapWidth), head = before ?? "", tail = after ?? ""
        let column = min(goalColumn, width - 1)
        let p = paragraphOffset(head)
        if direction < 0 {
            if p >= width { return .move(-(p - ((p / width - 1) * width + column))) }
            let rest = head.dropLast(p)
            if rest.last?.isNewline == true {
                let previous = rest.dropLast().reversed().prefix(while: { !$0.isNewline }).count
                let target = min((previous / width) * width + column, previous)
                return .move(-(p + 1 + (previous - target)))
            }
            // Nothing visible before this paragraph. Real UIKit reports nil at a paragraph's
            // start as well as the document's, so always cross over and look; at the very start
            // UIKit clamps the move.
            return .hop(-(p + 1))
        }
        let rest = tail.prefix(while: { !$0.isNewline }).count
        let nextLine = (p / width + 1) * width
        if nextLine <= p + rest { return .move(min(nextLine + column, p + rest) - p) }
        if tail.dropFirst(rest).first?.isNewline == true {
            let next = tail.dropFirst(rest + 1).prefix(while: { !$0.isNewline }).count
            return .move(rest + 1 + min(column, next))
        }
        return .hop(rest + 1) // nil at a paragraph's end too (see above); UIKit clamps at the end
    }

    /// After a `hop`, the column move inside the paragraph now around the caret: back from the
    /// end of the previous paragraph, or forward from the start of the next. The caller checks
    /// that the host has caught up (its context changed) before using it.
    public static func columnFix(_ direction: Int, goalColumn: Int, before: String?, after: String?,
                                 wrapWidth: Int) -> Int {
        let width = max(8, wrapWidth), column = min(goalColumn, width - 1)
        if direction < 0 {
            let length = paragraphOffset(before ?? "")
            return -(length - min((length / width) * width + column, length))
        }
        return min(column, (after ?? "").prefix(while: { !$0.isNewline }).count)
    }

    /// The column a run of vertical moves keeps, read from the caret's place in its paragraph.
    public static func column(before: String?, wrapWidth: Int) -> Int {
        paragraphOffset(before ?? "") % max(8, wrapWidth)
    }

    /// Signed characters to move for `lines` when the whole neighbourhood is in `before` and
    /// `after`, and the goal column to keep using. A hop past the known text stops there.
    public static func travel(lines: Int, goalColumn: Int?, before: String?, after: String?,
                              wrapWidth: Int) -> (characters: Int, goalColumn: Int) {
        var head = before ?? "", tail = after ?? ""
        let column = goalColumn ?? self.column(before: before, wrapWidth: wrapWidth)
        var total = 0
        for _ in 0..<min(abs(lines), 50) {
            var move: Int
            switch step(lines < 0 ? -1 : 1, goalColumn: column, before: head, after: tail, wrapWidth: wrapWidth) {
            case .move(let n): move = n
            case .hop(let n): move = n < 0 ? max(n, -head.count) : min(n, tail.count)
            case .none: move = 0
            }
            guard move != 0 else { break }
            total += move
            if move < 0 {
                let moved = String(head.suffix(-move)); head.removeLast(-move); tail = moved + tail
            } else {
                let moved = String(tail.prefix(move)); tail.removeFirst(move); head += moved
            }
        }
        return (total, column)
    }

    private static func paragraphOffset(_ head: String) -> Int {
        head.reversed().prefix(while: { !$0.isNewline }).count
    }
}

/// UIKit text positions use UTF-16 storage offsets. Convert visible-character travel using
/// fresh surrounding context, never splitting a composed accent, flag or ZWJ emoji.
/// Unknown context fails closed; do not guess a code-unit step through hidden text.
public enum CursorTextOffset {
    public static func utf16(steps: Int, before: String?, after: String?) -> Int {
        let bounded = min(SpacebarCursorGesture.maximumSteps, max(-SpacebarCursorGesture.maximumSteps, steps))
        if bounded < 0 { return -(before.map { String($0.suffix(-bounded)).utf16.count } ?? 0) }
        if bounded > 0 { return after.map { String($0.prefix(bounded)).utf16.count } ?? 0 }
        return 0
    }
}
