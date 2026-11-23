// by zayd/cold @ zayd.wtf

import Foundation

/// When a color Flash shows data and when the art takes over.
///
/// The screen's slots run `framesPerSecond` to the second. A flash opens with
/// `openingPictures` slots (the wordmark resolving into the first code, which also gives the
/// camera time to focus). After that, out of every `dataPictures + artPictures` slots the first
/// `dataPictures` are data, one picture a slot, and the rest are one interlude: the code
/// dissolves into the scene, the scene has the screen to itself, and the next code forms out of
/// it. The scene's own clock never stops, so the whole reads as one film intercut with data.
///
/// A data picture is always shown whole for its full slot. Only interlude and opening slots
/// show a code partly formed, and those are not meant to be read.
public struct LinkFlashSchedule: Equatable, Sendable {
    public let openingPictures: Int
    public let dataPictures: Int
    public let artPictures: Int
    /// Interludes in one act. The interlude that ends an act also changes the scene, so a long
    /// transfer moves through the scenes (`LinkFlashScene.act`). 0 keeps one scene throughout.
    public let interludesPerAct: Int

    public init(openingPictures: Int = 0, dataPictures: Int, artPictures: Int, interludesPerAct: Int = 0) {
        self.openingPictures = max(0, openingPictures)
        self.dataPictures = max(1, dataPictures)
        self.artPictures = max(0, artPictures)
        self.interludesPerAct = max(0, interludesPerAct)
    }

    /// Data only: black and white, and color with Reduce Motion.
    public static let dataOnly = LinkFlashSchedule(dataPictures: 1, artPictures: 0)

    /// The one place to tune the art's share of a color flash, at 20 slots a second:
    /// a 1 second opening, then 2 seconds of data (40 pictures) and a half-second interlude
    /// (10 slots), so an interlude every 2.5 seconds and a fifth of the time, under the quarter
    /// allowed. Every fourth interlude (every 10 seconds) changes the scene. The screen's
    /// large-area brightness changes once on the way into an interlude and once on the way
    /// out, eased over 150 ms each: under one a second, far below the three a second
    /// photosensitivity guidance sets as the limit.
    public static let color = LinkFlashSchedule(openingPictures: 20, dataPictures: 40, artPictures: 10, interludesPerAct: 4)

    /// Seconds the ending takes when the person taps Done: the code resolving back into the
    /// wordmark before the question appears.
    public static let endingSeconds = 0.7

    public enum Slot: Equatable, Sendable {
        /// The opening: which of its slots, from 0.
        case opening(step: Int)
        /// The data picture with this index, counting only data pictures, from 0.
        case data(Int)
        /// An interlude: which one (from 0), and which of its slots.
        case art(interlude: Int, step: Int)
    }

    public var period: Int { dataPictures + artPictures }

    /// The share of the time spent on data once the opening is over.
    public var dataShare: Double { Double(dataPictures) / Double(period) }

    public func slot(_ index: Int) -> Slot {
        let index = max(0, index)
        if index < openingPictures { return .opening(step: index) }
        let (round, within) = (index - openingPictures).quotientAndRemainder(dividingBy: period)
        if within < dataPictures { return .data(round * dataPictures + within) }
        return .art(interlude: round, step: within - dataPictures)
    }

    /// The slot in which data picture `index` is shown.
    public func slotIndex(ofData index: Int) -> Int {
        let index = max(0, index)
        return openingPictures + (index / dataPictures) * period + index % dataPictures
    }

    /// The act data picture `index` belongs to, from 0.
    public func act(ofData index: Int) -> Int {
        guard interludesPerAct > 0, artPictures > 0 else { return 0 }
        return (max(0, index) / dataPictures) / interludesPerAct
    }

    /// True when interlude `interlude` ends an act, so the scene changes during it.
    public func changesScene(atInterlude interlude: Int) -> Bool {
        interludesPerAct > 0 && (interlude + 1) % interludesPerAct == 0
    }

    /// Seconds for a flash with this schedule, when the camera misses nothing: the opening,
    /// the data pictures the computer needs, and the interludes that fall between them.
    public func seconds(for plan: LinkFlashPlan) -> Double {
        let rate = Double(max(1, plan.framesPerSecond))
        let pictures = Int((plan.seconds * rate).rounded(.up))
        return Double(slots(forPictures: pictures)) / rate
    }

    /// Slots from the start of a flash until `pictures` data pictures have been shown.
    public func slots(forPictures pictures: Int) -> Int {
        let pictures = max(0, pictures)
        let interludes = artPictures > 0 && pictures > 0 ? (pictures - 1) / dataPictures : 0
        return openingPictures + pictures + interludes * artPictures
    }

    // MARK: The shape of an interlude and of the opening

    /// The share of an interlude spent dissolving the code into the scene, and the same again
    /// forming the next code out of it. Between the two the scene has the screen to itself.
    public static let interludeTurn = 0.3
    /// The share of the opening the wordmark holds still before it starts turning into the code.
    public static let openingHold = 0.55

    /// How much of the code is on screen `through` (0 to 1) an interlude: 1 is the whole code,
    /// 0 none of it. It falls to 0, stays there, and rises back, eased at both ends so the
    /// screen's brightness never steps.
    public static func codePresence(through: Double) -> Double {
        let t = min(max(through, 0), 1)
        if t < interludeTurn { return 1 - ease(t / interludeTurn) }
        if t > 1 - interludeTurn { return ease((t - (1 - interludeTurn)) / interludeTurn) }
        return 0
    }

    /// True in the second half of an interlude, when what forms is the next data picture, in
    /// the next act's scene and palette when the act changes.
    public static func showsNextPicture(through: Double) -> Bool { through >= 0.5 }

    /// How far the wordmark has turned into the first code `through` (0 to 1) the opening:
    /// 0 is the wordmark alone, 1 the code.
    public static func openingReveal(through: Double) -> Double {
        let t = min(max(through, 0), 1)
        guard t > openingHold else { return 0 }
        return ease((t - openingHold) / (1 - openingHold))
    }

    /// Smoothstep: no sudden start or stop.
    public static func ease(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }
}
