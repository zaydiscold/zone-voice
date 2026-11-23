// by zayd/cold @ zayd.wtf

import Foundation
import Observation
import ZoneCore

/// Apple's rating prompt, asked only right after something worked (see `ReviewPromptPolicy`).
///
/// The coordinators report each dictation, note and meeting that finished with words and no
/// error. Keyboard dictations count too: the app recognizes them, usually while it is in the
/// background, so they count without asking. A success while Zone is on screen bumps
/// `askRequests`; RootView then waits a moment, checks again and hands the request to iOS,
/// which decides whether anything appears (at most three times a year).
@MainActor
@Observable
final class ReviewPrompter {
    /// Bumped when a success on screen may ask. RootView watches it.
    private(set) var askRequests = 0
    @ObservationIgnored private let store: ReviewPromptStore
    @ObservationIgnored let appVersion: String

    init(store: ReviewPromptStore = ReviewPromptStore(),
         appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") {
        self.store = store
        self.appVersion = appVersion
    }

    var state: ReviewPromptState { store.state }

    /// At launch: starts the two-day clock the first time only.
    func noteLaunch(now: Date = Date()) {
        store.noteLaunch(now: now)
    }

    /// A recording ended well.
    /// - Parameter onScreen: Zone is the active app, so the person just saw it work.
    func recordSuccess(onScreen: Bool, now: Date = Date()) {
        let state = store.recordSuccess(now: now)
        guard onScreen, ReviewPromptPolicy.shouldAsk(state, now: now, appVersion: appVersion,
                                                     isRecording: false, showsError: false) else { return }
        askRequests += 1
    }

    /// The last check before asking iOS, with what is on screen now. True means ask, and the
    /// version is recorded as asked whether or not iOS shows the prompt.
    func claimAsk(isRecording: Bool, showsError: Bool, now: Date = Date()) -> Bool {
        guard ReviewPromptPolicy.shouldAsk(store.state, now: now, appVersion: appVersion,
                                           isRecording: isRecording, showsError: showsError) else { return false }
        store.markAsked(version: appVersion)
        return true
    }
}
