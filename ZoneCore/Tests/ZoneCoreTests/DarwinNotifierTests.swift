// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class DarwinNotifierTests: XCTestCase {
    /// Darwin notifications are delivered within a process too, so a post must reach an
    /// observer registered for the same name. This is the cross-process handshake's one
    /// moving part, and a registry key mismatch once made every ping vanish silently.
    @MainActor
    func testPostReachesObserver() async throws {
        let received = expectation(description: "requestChanged delivered")
        let observation = DarwinNotifier.observe(.requestChanged) {
            received.fulfill()
        }
        defer { observation.cancel() }
        DarwinNotifier.post(.requestChanged)
        await fulfillment(of: [received], timeout: 2)
    }

    @MainActor
    func testOtherNamesDoNotTrigger() async throws {
        let notExpected = expectation(description: "statusChanged must not fire")
        notExpected.isInverted = true
        let observation = DarwinNotifier.observe(.statusChanged) {
            notExpected.fulfill()
        }
        defer { observation.cancel() }
        DarwinNotifier.post(.resultReady)
        await fulfillment(of: [notExpected], timeout: 0.5)
    }

    @MainActor
    func testCancellingOneObserverKeepsTheOther() async throws {
        let survivor = expectation(description: "second observer still fires")
        let first = DarwinNotifier.observe(.controlChanged) { }
        let second = DarwinNotifier.observe(.controlChanged) { survivor.fulfill() }
        defer { second.cancel() }
        first.cancel()
        DarwinNotifier.post(.controlChanged)
        await fulfillment(of: [survivor], timeout: 2)
    }

    @MainActor
    func testCancelStopsDelivery() async throws {
        let notExpected = expectation(description: "cancelled observer must not fire")
        notExpected.isInverted = true
        let observation = DarwinNotifier.observe(.sessionChanged) {
            notExpected.fulfill()
        }
        observation.cancel()
        DarwinNotifier.post(.sessionChanged)
        await fulfillment(of: [notExpected], timeout: 0.5)
    }
}
