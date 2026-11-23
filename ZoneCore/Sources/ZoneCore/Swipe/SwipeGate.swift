// by zayd/cold @ zayd.wtf

import Foundation

/// When a touch on a letter key stops being a tap and becomes a swipe.
///
/// Turning swipe on must never make tapping worse (the loudest complaint about Apple's
/// Slide to Type is that it does). So a tap stays a tap: the key is decided at touch-down and
/// a thumb that rolls stays within the grid's release tolerance. A touch is promoted to a
/// swipe only when it has travelled further than a threshold that depends on how recently the
/// last key was tapped (LatinIME's rule: right after a tap the finger must travel further
/// before a gesture starts, so a fast typist's rolls never become swipes) and is moving at
/// swipe speed. Anything that travels a long way is a swipe regardless of speed.
public struct SwipeGate: Equatable, Sendable {
    /// Travel needed well after the last tap, in pitches. Below one pitch so adjacent-key words
    /// such as "as", "we" and "op" can be swiped.
    public var restingThreshold: Float = 0.65
    /// Travel needed in the instant after a tap; decays to `restingThreshold` over `decay`.
    public var afterTapThreshold: Float = 2.5
    public var decay: Double = 0.4
    /// Mean speed, in pitches per second, below which a short movement is a slide, not a swipe.
    public var minimumSpeed: Float = 1.5
    /// Travel beyond which the touch is a swipe whatever its speed.
    public var certainTravel: Float = 2.5

    public init() {}

    /// - Parameters:
    ///   - travel: arc length of the touch so far, in pitches.
    ///   - duration: seconds since the touch began.
    ///   - sinceLastTap: seconds since the last key was tapped; nil if none this appearance.
    public func isSwipe(travel: Float, duration: Double, sinceLastTap: Double?) -> Bool {
        guard travel.isFinite, travel > 0 else { return false }
        if travel >= certainTravel { return true }
        var threshold = restingThreshold
        if let since = sinceLastTap, since < decay, since >= 0 {
            let remaining = Float(1 - since / decay)
            threshold = restingThreshold + (afterTapThreshold - restingThreshold) * remaining
        }
        guard travel >= threshold else { return false }
        let speed = duration > 0.005 ? travel / Float(duration) : .infinity
        return speed >= minimumSpeed
    }
}
