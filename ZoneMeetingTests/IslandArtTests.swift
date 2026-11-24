// by zayd/cold @ zayd.wtf

import SwiftUI
import XCTest
@testable import Zone

/// The island's art looks: Stream's words, the themes, the petals' flight and the heart's beat.
final class IslandArtTests: XCTestCase {
    func testPortraitsFitTheSideCircleAndKeepTheirIdentityAtRest() throws {
        var hashes = Set<Data>()
        for look in IslandLook.allCases where !look.spins {
            var mood = IslandMood(kind: .listening)
            mood.beat = 1
            let image = try XCTUnwrap(IslandPixelArt.image(look: look, mood: mood, accent: 0xC48AFF, side: true, still: true))
            let pixels = try XCTUnwrap(image.dataProvider?.data) as Data
            XCTAssertTrue(hashes.insert(pixels).inserted, look.title)
            var pigments = Set<Data>()
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let offset = (y * image.width + x) * 4
                    if pixels[offset + 3] == 0 { continue }
                    pigments.insert(pixels.subdata(in: offset..<(offset + 3)))
                    // A 21-point picture is centered inside a 28-point circular presentation.
                    XCTAssertLessThan(hypot(Double(x - 9), Double(y - 9)) * 21 / 19, 14, look.title)
                }
            }
            XCTAssertGreaterThanOrEqual(pigments.count, 3, look.title)
            mood.beat = 2
            let reduced = try XCTUnwrap(IslandPixelArt.image(look: look, mood: mood, accent: 0xC48AFF, side: true, still: true))
            XCTAssertEqual(reduced.dataProvider?.data as Data?, pixels, look.title)
        }
    }

    // MARK: Stream

    func testStreamShowsTheNewestWordAndTheOneBefore() {
        let words = IslandStream.words("meet me at the station")
        XCTAssertEqual(words.newest, "station")
        XCTAssertEqual(words.previous, "the")
    }

    func testStreamBeforeAndAtTheFirstWord() {
        XCTAssertNil(IslandStream.words(nil).newest)
        XCTAssertNil(IslandStream.words("").newest)
        XCTAssertNil(IslandStream.words(" ").newest)
        let one = IslandStream.words("hello")
        XCTAssertEqual(one.newest, "hello")
        XCTAssertNil(one.previous, "nothing came before the first word")
    }

    func testStreamKeepsTheEndOfALongWordAndDropsTheCaptionsEllipsis() {
        XCTAssertEqual(IslandStream.clip("internationalization"), "…lization")
        XCTAssertEqual(IslandStream.clip("…cut"), "cut")
        // The caption's tail begins with an ellipsis once it is cut; that is not a word.
        let words = IslandStream.words(IslandCaption.tail(of: String(repeating: "word ", count: 30) + "last"))
        XCTAssertEqual(words.newest, "last")
        XCTAssertEqual(words.previous, "word")
        XCTAssertLessThanOrEqual(IslandStream.clip("internationalization").count, IslandStream.maxCharacters)
    }

    func testStreamNeverShowsPunctuation() {
        let words = IslandStream.words(IslandCaption.tail(of: "Wait, really? Yes."))
        XCTAssertEqual(words.newest, "Yes")
        XCTAssertEqual(words.previous, "really")
    }

    // MARK: Looks and themes

    @MainActor
    func testRoseGrowthAndSynthHistoryChangeTheRenderedFigure() throws {
        func picture(_ state: RecordingActivityAttributes.ContentState) throws -> Data {
            let kit = IslandKit(state: state)
            let renderer = ImageRenderer(content: IslandFigure(look: kit.look, mood: kit.mood,
                tint: .pink, height: 36).frame(width: 84, height: 52).background(.black))
            renderer.scale = 3
            return try XCTUnwrap(renderer.uiImage?.pngData())
        }
        var state = RecordingActivityAttributes.ContentState(phase: .recording, noteMode: false, startedAt: Date())
        state.gallery = true
        state.look = .rose
        state.words = 0
        let bud = try picture(state)
        state.words = 40
        XCTAssertNotEqual(try picture(state), bud)
        state.look = .synth
        state.levels = [0, 0, 0, 0, 0, 0, 0]
        let quiet = try picture(state)
        state.levels = [0, 0, 5, 15, 3, 1, 11, 7]
        XCTAssertEqual(IslandKit(state: state).mood.synthLevels, [0, 5, 15, 3, 1, 11, 7])
        XCTAssertNotEqual(try picture(state), quiet)
    }

    func testCubeAndSwordSpinContinuouslyThenCoastToRest() throws {
        let zero = Date(timeIntervalSinceReferenceDate: 10)
        let driving = IslandSpin.resting(at: zero).retarget(0.7, at: zero)
        let stop = zero.addingTimeInterval(1.6)
        let before = driving.sample(at: stop)
        let release = driving.retarget(0, at: stop)
        XCTAssertEqual(release.turns, before.turns, accuracy: 0.00001)
        XCTAssertEqual(release.speed, before.speed, accuracy: 0.00001)
        XCTAssertGreaterThan(release.sample(at: stop.addingTimeInterval(0.3)).turns, before.turns)
        XCTAssertLessThan(release.sample(at: stop.addingTimeInterval(3)).speed, 0.002)
        XCTAssertEqual(try JSONDecoder().decode(IslandSpin.self, from: JSONEncoder().encode(release)), release)
    }

    func testOldChoicesResolveToOneLook() {
        for look in IslandLook.allCases {
            for palette in IslandPalette.allCases {
                let expected: IslandLook = look == .halo && palette == .blackout ? .blackout : look
                XCTAssertEqual(IslandLook.restored(look, palette: palette), expected)
            }
        }
        XCTAssertEqual(IslandLook.restored(.stream, palette: .accent).title, "Stenographer")
        XCTAssertEqual(IslandLook.restored(.loop, palette: .amber).title, "Ember")
        XCTAssertEqual(IslandLook.restored(.drift, palette: .rose).title, "Blossom")
        XCTAssertEqual(Set(IslandLook.allCases.map(\.title)).count, IslandLook.allCases.count)
    }

    func testMovingPetalsGlideSlowlyAndCannotSpin() {
        for beat in 0..<500 {
            let petal = PetalsShape(phase: Double(beat), wind: 1, settle: 0).petal(0)
            let next = PetalsShape(phase: Double(beat + 1), wind: 1, settle: 0).petal(0)
            let advance = (1 + next.x - petal.x).truncatingRemainder(dividingBy: 1)
            XCTAssertTrue((0.017...0.031).contains(advance))
            XCTAssertLessThan(abs(petal.turn), 0.35)
        }
    }

    // MARK: Petals

    func testPetalsStayInTheFieldWhateverTheWindAndHoweverLongItBlows() {
        for layer in 0..<2 {
            for step in 0..<400 {
                let shape = PetalsShape(phase: Double(step) * 0.37, wind: Double(step % 11) / 10,
                                        settle: Double(step % 5) / 4, count: 6, layer: layer)
                for i in 0..<6 {
                    let petal = shape.petal(i)
                    XCTAssertTrue((0..<1).contains(petal.x), "x \(petal.x)")
                    XCTAssertTrue((0.05...0.95).contains(petal.y), "y \(petal.y) at step \(step)")
                    XCTAssertTrue(petal.size > 0.2 && petal.size < 0.5)
                }
            }
        }
    }

    func testFallenPetalsLieOnTheFloorAndStopTurning() {
        let early = PetalsShape(phase: 3, wind: 0.2, settle: 1, count: 4)
        let late = PetalsShape(phase: 3, wind: 0.9, settle: 1, count: 4)
        for i in 0..<4 {
            XCTAssertGreaterThan(early.petal(i).y, 0.75, "on the floor")
            XCTAssertEqual(early.petal(i).y, late.petal(i).y, accuracy: 1e-9, "the wind does not lift a fallen petal")
            XCTAssertLessThan(abs(early.petal(i).turn), 0.4, "lying nearly flat")
        }
    }

    func testAPetalMovesALittleEachUpdateAndNeverJumpsExceptAtTheEdge() {
        // One update is one step of phase. Between two updates a petal moves under a quarter of
        // the field, or it has left one edge and come in at the other.
        for i in 0..<5 {
            for step in 0..<200 {
                let a = PetalsShape(phase: Double(step), wind: 0.6, settle: 0, count: 5).petal(i)
                let b = PetalsShape(phase: Double(step + 1), wind: 0.6, settle: 0, count: 5).petal(i)
                let moved = b.x - a.x
                XCTAssertTrue((0..<0.25).contains(moved) || moved < -0.75, "petal \(i) moved \(moved) at \(step)")
            }
        }
    }

    func testThePathIsNeverEmptyAndFitsItsRect() {
        let rect = CGRect(x: 0, y: 0, width: 150, height: 38)
        let bounds = PetalsShape(phase: 12.3, wind: 1, settle: 0, count: 6).path(in: rect).boundingRect
        XCTAssertFalse(bounds.isEmpty)
        XCTAssertTrue(rect.insetBy(dx: -20, dy: -20).contains(bounds), "\(bounds)")
    }

    // MARK: The heart

    func testTheHeartRestsBetweenBeatsAndBeatsTwiceASecondWhileRecording() {
        // At rest: one swell at the top of every other second.
        XCTAssertEqual(BeatingHeart.scale(at: 10.1, quick: false), 1)
        XCTAssertEqual(BeatingHeart.scale(at: 10.5, quick: false), BeatingHeart.rest)
        XCTAssertEqual(BeatingHeart.scale(at: 11.1, quick: false), BeatingHeart.rest, "nothing in the odd second")
        // Recording: lub, a gap, dub, then rest, every second.
        for second in [20.0, 21.0] {
            XCTAssertEqual(BeatingHeart.scale(at: second + 0.05, quick: true), 1, "lub")
            XCTAssertEqual(BeatingHeart.scale(at: second + 0.22, quick: true), BeatingHeart.rest, "between")
            XCTAssertEqual(BeatingHeart.scale(at: second + 0.35, quick: true), 1, "dub")
            XCTAssertEqual(BeatingHeart.scale(at: second + 0.7, quick: true), BeatingHeart.rest)
        }
    }

    func testAGateWindowIsAlwaysShorterThanTheFontsSecond() {
        // Two timers a fraction of a second apart overlap for that fraction; a window of a
        // second or more would need a third.
        for window in [BeatingHeart.lub, BeatingHeart.dub] {
            XCTAssertGreaterThan(window.1, 0)
            XCTAssertLessThan(window.0 + window.1, 1)
        }
        XCTAssertLessThan(BeatingHeart.lub.0 + BeatingHeart.lub.1, BeatingHeart.dub.0, "lub ends before dub begins")
    }

    func testTheGateFontsAreInTheIslandsBundle() throws {
        // Without them the timers would draw as digits. They ship in the widget extension only.
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let island = plugins.appendingPathComponent("ZoneActivity.appex")
        let fonts = try XCTUnwrap(NSDictionary(contentsOf: island.appendingPathComponent("Info.plist"))?["UIAppFonts"] as? [String])
        XCTAssertEqual(Set(fonts), ["ZoneGateOne.ttf", "ZoneGateEven.ttf"])
        for font in fonts {
            XCTAssertTrue(FileManager.default.fileExists(atPath: island.appendingPathComponent(font).path), font)
        }
        XCTAssertEqual(IslandGate.Period.two.rawValue, "ZoneGateEven-Regular")
        XCTAssertEqual(IslandGate.Period.ten.rawValue, "ZoneGateOne-Regular")
    }

    // MARK: The pulse line

    func testTheTraceIsFlatWithNoVoiceAndTallWithOne() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 30)
        let flat = PulseLine(position: 0.5, amplitude: 0).path(in: rect).boundingRect
        let tall = PulseLine(position: 0.5, amplitude: 1).path(in: rect).boundingRect
        XCTAssertLessThan(flat.height, 0.5)
        XCTAssertGreaterThan(tall.height, 20)
        XCTAssertTrue(rect.insetBy(dx: -1, dy: -1).contains(tall))
    }
}
