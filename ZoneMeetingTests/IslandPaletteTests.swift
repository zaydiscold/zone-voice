// by zayd/cold @ zayd.wtf

import ActivityKit
import SwiftUI
import XCTest
import ZoneCore
@testable import Zone

/// Settings > Dynamic Island: the switch at the top governs the island, and the app accent
/// reaches the card. Through the real settings, coordinator and Live Activity.
@MainActor
final class IslandPaletteTests: XCTestCase {
    private var suite: String!
    private var settings: AppSettings!
    private var coordinator: DictationCoordinator?
    private var card: RecordingLiveActivity?

    override func setUpWithError() throws {
        suite = "island-palette-" + UUID().uuidString
        settings = AppSettings(defaults: UserDefaults(suiteName: suite)!, store: UserDefaultsSharedStore(suiteName: suite))
        settings.soundsEnabled = false
        settings.startsSessionOnOpen = false
    }

    override func tearDownWithError() throws {
        coordinator?.endSession(reason: .user)
        card?.end()
        coordinator = nil
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    func testAccentAndLabelFollowTheSameTraits() {
        let store = AccentStore.shared
        let original = store.choice
        defer { store.choice = original }
        for choice in AccentChoice.allCases {
            store.choice = choice
            for style: UIUserInterfaceStyle in [.unspecified, .light, .dark] {
                let traits = UITraitCollection(userInterfaceStyle: style)
                let scheme: ColorScheme = style == .dark ? .dark : .light
                let fill = Color(hex: scheme == .dark ? choice.darkHex : choice.lightHex)
                let control = Color(hex: choice.controlFillHex(isDark: scheme == .dark))
                let ink = Color(hex: choice.controlInkHex(isDark: scheme == .dark))
                for (actual, expected) in [(Zone.accentTone, fill), (Zone.controlFill(scheme), control),
                                            (Zone.accentTone(scheme), fill), (Zone.controlInk(scheme), ink)] {
                    let space = CGColorSpace(name: CGColorSpace.sRGB)!
                    let resolved = UIColor(actual).resolvedColor(with: traits).cgColor
                    let target = UIColor(expected).cgColor
                    let actualRGB = resolved.converted(to: space, intent: .relativeColorimetric, options: nil)?.components
                    let expectedRGB = target.converted(to: space, intent: .relativeColorimetric, options: nil)?.components
                    XCTAssertEqual(actualRGB?.count, 4)
                    for (a, b) in zip(actualRGB ?? [], expectedRGB ?? []) {
                        XCTAssertEqual(a, b, accuracy: 0.002, "\(choice) / \(style.rawValue)")
                    }
                }
            }
        }
    }

    // MARK: Out of the gate

    func testAFreshInstallHasZonesIslandWithEverythingOn() {
        XCTAssertTrue(settings.islandWhileReady, "Zone owns the island from the first launch")
        XCTAssertEqual(settings.islandLook, .halo)
        XCTAssertEqual(settings.islandPalette, .accent)
        XCTAssertTrue(settings.islandControls)
        let style = settings.islandStyle
        XCTAssertEqual(style.look, .halo)
        XCTAssertEqual(style.palette, .accent)
        XCTAssertTrue(style.controls)
    }

    func testTheColorIsKept() {
        settings.islandPalette = .blackout
        let again = AppSettings(defaults: UserDefaults(suiteName: suite)!, store: UserDefaultsSharedStore(suiteName: suite))
        XCTAssertEqual(again.islandPalette, .blackout)
    }

    func testAnUnknownStoredColorFallsBackToTheAccent() {
        UserDefaults(suiteName: suite)!.set("plaid", forKey: "zone.settings.islandPalette")
        let again = AppSettings(defaults: UserDefaults(suiteName: suite)!, store: UserDefaultsSharedStore(suiteName: suite))
        XCTAssertEqual(again.islandPalette, .accent)
    }

    // MARK: The switch at the top

    func testOldPalettePreservesTheSelectedLookAndUsesTheAppAccent() {
        settings.islandLook = .recorder
        settings.islandPalette = .green
        settings.islandControls = false
        let style = settings.islandStyle
        XCTAssertEqual(style.look, .recorder)
        XCTAssertEqual(settings.islandLook, .recorder)
        XCTAssertEqual(settings.islandPalette, .green)
        XCTAssertEqual(style.palette, .accent)
        XCTAssertFalse(style.controls)
    }

    func testDevelopmentBuildKeepsGalleryAndEveryShippedClassicChoice() {
        XCTAssertTrue(AppSettings.showsIslandGallery)
        XCTAssertEqual(IslandLook.classic, [.halo, .recorder, .caption, .ghost])
    }

    func testCachedBetaCardNeedsGalleryFlagToRenderArt() {
        var state = RecordingActivityAttributes.ContentState(phase: .ready, noteMode: false, startedAt: Date())
        state.look = .drift
        state.palette = .rose
        XCTAssertEqual(IslandKit(state: state).look, .halo)
        state.gallery = true
        XCTAssertEqual(IslandKit(state: state).look, .drift)
        state.accentChoice = AccentChoice.rose.rawValue
        XCTAssertEqual(IslandKit(state: state).tint, Color(hex: AccentChoice.rose.darkHex))
    }

    func testEverySavedGalleryLookIsRestoredInTheApp() {
        for look in IslandLook.allCases {
            settings.islandLook = look
            XCTAssertEqual(settings.islandStyle.look, look)
            XCTAssertEqual(settings.islandLook, look)
        }
    }

    func testOffTheHiddenChoicesNoLongerApply() {
        settings.islandLook = .caption
        settings.islandPalette = .blackout
        settings.islandControls = false
        settings.islandWhileReady = false
        let style = settings.islandStyle
        XCTAssertEqual(style.look, .ghost, "Off, a recording's island is the plain dot")
        XCTAssertEqual(style.palette, .accent)
        XCTAssertTrue(style.controls, "and it keeps Stop, so a recording can always be stopped")
        // Turning it back on restores what the person chose; nothing was overwritten.
        settings.islandWhileReady = true
        XCTAssertEqual(settings.islandStyle.look, .caption)
        XCTAssertEqual(settings.islandStyle.palette, .accent)
        XCTAssertFalse(settings.islandStyle.controls)
    }

    // MARK: The card

    /// The coordinator stamps the governed style on every card it sends.
    func testTheCardCarriesTheChosenColorAndTheSwitchGovernsIt() throws {
        let card = RecordingLiveActivity()
        self.card = card
        coordinator = DictationCoordinator(settings: settings, store: UserDefaultsSharedStore(suiteName: suite),
                                           engine: PaletteSpeechEngine(), requestSessionPermission: { true },
                                           recordingLiveActivity: card)
        settings.islandLook = .recorder
        settings.islandPalette = .blackout
        card.standby(until: Date().addingTimeInterval(300), canCreate: true)
        try XCTSkipUnless(card.isActive, "No Live Activity in this environment")
        var state = try XCTUnwrap(card.latestState)
        XCTAssertEqual(state.palette, .accent)
        XCTAssertEqual(state.look, .recorder)
        XCTAssertEqual(state.gallery, true)

        settings.islandWhileReady = false
        card.standby(until: Date().addingTimeInterval(300), canCreate: false)
        state = try XCTUnwrap(card.latestState)
        XCTAssertEqual(state.palette, .accent)
        XCTAssertEqual(state.look, .ghost)
    }

    func testMeetingStartHoldAndRebuiltCardCarryAppearance() async throws {
        let previousAccent = AccentChoice.stored
        defer {
            let shared = UserDefaults(suiteName: ZoneContract.appGroup)
            shared?.set(previousAccent?.rawValue, forKey: AccentChoice.defaultsKey)
            AccentStore.shared.choice = previousAccent ?? .defaultChoice
        }
        let dictation = DictationCoordinator(settings: settings, store: UserDefaultsSharedStore(suiteName: suite),
                                             engine: PaletteSpeechEngine(), requestSessionPermission: { true })
        coordinator = dictation
        let meeting = MeetingLiveActivity { dictation.meetingIslandColors }
        defer { meeting.end() }
        settings.accent = .ember
        settings.islandPalette = .accent
        let title = "Appearance test " + UUID().uuidString

        meeting.start(title: title)
        let first = try XCTUnwrap(Activity<RecordingActivityAttributes>.activities.first {
            $0.content.state.meetingTitle == title && $0.activityState == .active
        })
        XCTAssertEqual(first.content.state.accentChoice, AccentChoice.ember.rawValue)
        XCTAssertEqual(first.content.state.palette, .accent)

        settings.accent = .ice
        meeting.refreshAppearance()
        let colorDeadline = Date().addingTimeInterval(3)
        while first.content.state.accentChoice != AccentChoice.ice.rawValue, Date() < colorDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(first.content.state.accentChoice, AccentChoice.ice.rawValue)

        meeting.update(state: .interrupted, recordedSeconds: 9)
        let deadline = Date().addingTimeInterval(3)
        while first.content.state.meetingHeld != true, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(first.content.state.meetingHeld, true)
        XCTAssertEqual(first.content.state.accentChoice, AccentChoice.ice.rawValue)
        XCTAssertEqual(first.content.state.palette, .accent)
        await first.end(nil, dismissalPolicy: .immediate)
        let endedDeadline = Date().addingTimeInterval(3)
        // ActivityKit delivers the state change after end() returns.
        while meeting.isActive, Date() < endedDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(meeting.isActive)

        settings.islandPalette = .blackout
        meeting.start(title: title, state: .recording, recordedSeconds: 9)
        let replacement = try XCTUnwrap(Activity<RecordingActivityAttributes>.activities.first {
            $0.content.state.meetingTitle == title && $0.id != first.id && $0.activityState == .active
        })
        XCTAssertEqual(replacement.content.state.accentChoice, AccentChoice.ice.rawValue)
        XCTAssertEqual(replacement.content.state.palette, .accent)
        XCTAssertEqual(replacement.content.state.phase, .recording)
        XCTAssertEqual(Date().timeIntervalSince(replacement.content.state.startedAt), 9, accuracy: 2)
    }

    // MARK: The palettes

    func testAnOlderCardWithNoColorDecodesAsTheAccent() throws {
        let json = #"{"phase":"ready","noteMode":false,"startedAt":0}"#
        let state = try JSONDecoder().decode(RecordingActivityAttributes.ContentState.self, from: Data(json.utf8))
        XCTAssertNil(state.palette, "An older payload has no color, which the island reads as the accent")
        var with = state
        with.palette = .amber
        let round = try JSONDecoder().decode(RecordingActivityAttributes.ContentState.self,
                                             from: JSONEncoder().encode(with))
        XCTAssertEqual(round.palette, .amber)
    }

    func testFullBlackUsesOnlyTheAccentForMarksAndText() {
        var state = RecordingActivityAttributes.ContentState(phase: .ready, noteMode: false, startedAt: Date())
        state.gallery = true
        state.look = .halo
        state.palette = .blackout
        for accent in [AccentChoice.ice, .violet] {
            state.accentChoice = accent.rawValue
            let kit = IslandKit(state: state)
            XCTAssertEqual(kit.look, .blackout)
            XCTAssertEqual(kit.ink, Color(hex: accent.darkHex))
            XCTAssertEqual(kit.tint, kit.ink)
        }
    }

    func testEverySavedColorDecodesAndEveryLookFollowsTheAppAccent() throws {
        let oldKeys = ["accent", "blackout", "graphite", "red", "amber", "green", "bone", "rose"]
        var state = RecordingActivityAttributes.ContentState(phase: .recording, noteMode: false, startedAt: Date())
        state.gallery = true
        for key in oldKeys {
            state.palette = try JSONDecoder().decode(IslandPalette.self, from: JSONEncoder().encode(key))
            for look in IslandLook.allCases {
                state.look = look
                for accent in [AccentChoice.ice, .violet] {
                    state.accentChoice = accent.rawValue
                    XCTAssertEqual(IslandKit(state: state).tint, Color(hex: accent.darkHex))
                }
            }
        }
    }
}

private final class PaletteSpeechEngine: SpeechEngine {
    let kind: EngineKind = .fluidMiniCPU
    var isReady = true
    func assetsPresent() -> Bool { true }
    func bytesOnDisk() -> Int64 { 0 }
    func removeAssets() throws {}
    func downloadAssets(progress: @escaping @Sendable (Double, String) -> Void) async throws {}
    func prepare(progress: @escaping @Sendable (Double, String) -> Void) async throws {}
    func setContextHints(_ text: String) {}
    func beginUtterance() throws -> UtteranceSession { throw CancellationError() }
    func unload() {}
}
