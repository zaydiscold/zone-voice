// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class DictationRouteTests: XCTestCase {
    private func route(fullAccess: Bool = true, folder: Bool = true, alive: Bool, asked: Bool = false,
                       hold: Bool = false, keyboard: Bool) -> DictationRoute {
        DictationRoute.resolve(.init(hasFullAccess: fullAccess, sharedFolderReachable: folder, sessionAlive: alive,
                                     personAskedForZone: asked, fromHold: hold, keyboardCanRecord: keyboard))
    }

    /// Every combination of the six inputs, against the table written out by hand.
    func testTheWholeTable() {
        for fullAccess in [true, false] {
            for folder in [true, false] {
                for alive in [true, false] {
                    for asked in [true, false] {
                        for hold in [true, false] {
                            for keyboard in [true, false] {
                                let expected: DictationRoute
                                if !fullAccess { expected = .setUp(.fullAccess) }
                                else if !folder { expected = .setUp(.sharedFolder) }
                                else if asked && !hold { expected = .opensZone(.personAsked) }
                                else if alive { expected = .warm }
                                else if keyboard { expected = .inKeyboard }
                                else if hold { expected = .notReady }
                                else { expected = .opensZone(.keyboardCannotRecord) }
                                XCTAssertEqual(route(fullAccess: fullAccess, folder: folder, alive: alive, asked: asked,
                                                     hold: hold, keyboard: keyboard), expected,
                                               "fullAccess \(fullAccess) folder \(folder) alive \(alive) asked \(asked) hold \(hold) keyboard \(keyboard)")
                            }
                        }
                    }
                }
            }
        }
    }

    func testAWarmSessionKeepsThePersonInTheirApp() {
        XCTAssertEqual(route(alive: true, keyboard: true), .warm)
        XCTAssertEqual(route(alive: true, keyboard: false), .warm)
    }

    /// 2026-11-22, CarPlay: the session had just ended. With the keyboard able to record, the
    /// press stays here; otherwise the same press opens Zone. Neither is an error line.
    func testAPressThatOutlivedItsSessionStillActs() {
        XCTAssertEqual(route(alive: false, keyboard: true), .inKeyboard)
        XCTAssertEqual(route(alive: false, keyboard: false), .opensZone(.keyboardCannotRecord))
    }

    func testAHoldNeverOpensZone() {
        for asked in [true, false] {
            XCTAssertEqual(route(alive: false, asked: asked, hold: true, keyboard: false), .notReady)
            XCTAssertEqual(route(alive: false, asked: asked, hold: true, keyboard: true), .inKeyboard)
            XCTAssertEqual(route(alive: true, asked: asked, hold: true, keyboard: false), .warm)
        }
    }

    func testATapOnTheOpenZoneLineOpensZoneEvenWhenTheKeyboardCouldRecord() {
        XCTAssertEqual(route(alive: true, asked: true, keyboard: true), .opensZone(.personAsked))
        XCTAssertEqual(route(alive: false, asked: true, keyboard: true), .opensZone(.personAsked))
    }

    func testEveryRouteHasItsOwnLogName() {
        let all: [DictationRoute] = [.setUp(.fullAccess), .setUp(.sharedFolder), .warm, .inKeyboard,
                                     .opensZone(.personAsked), .opensZone(.keyboardCannotRecord), .notReady]
        XCTAssertEqual(Set(all.map(\.journalName)).count, all.count)
    }
}
