// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

/// A word fixed by hand after a dictation: a slip made while fixing it is not shielded from
/// autocorrect (and so not learned), a word the person insists on is, and the unsure-word check
/// hears of every hand fix.
@MainActor final class CorrectionLearningTests: XCTestCase {
    typealias Proxy = SwipeIntegrationTests.Proxy
    private func prepared(_ p: Proxy) async throws -> KeyboardModel {
        let m = KeyboardModel(proxy: p)
        m.refreshTraits()
        m.apply(KeyboardPreferences(autocorrectEnabled: true, swipeTypingEnabled: false))
        for _ in 0..<200 where !m.isCorrectorReady {
            m.handleTap(.character("q")); m.keyDown(.delete); m.endDeleteRepeat()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(m.isCorrectorReady)
        p.text = ""
        return m
    }
    private func type(_ text: String, _ m: KeyboardModel) {
        for character in text {
            if character == " " { m.handleTap(.space) } else { m.handleTap(.character(String(character))) }
        }
    }
    private func backspace(_ count: Int, _ m: KeyboardModel) {
        for _ in 0..<count { m.keyDown(.delete); m.endDeleteRepeat() }
    }
    /// The mic inserts text behind the keyboard's back, then tells the model.
    private func dictate(_ text: String, _ p: Proxy, _ m: KeyboardModel) {
        p.insert(text)
        m.dictationInserted(text)
    }

    func testLoadingTheCorrectorSharesTheAppearanceVocabularyRead() async throws {
        let proxy = Proxy()
        proxy.hasOpenAccess = true
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersonalVocabulary(fileURL: root.appendingPathComponent("words.json"))
        try store.add(["QuillBerry"])
        let model = KeyboardModel(proxy: proxy, vocabulary: { store })
        model.refreshFullAccess(reloadVocabulary: false)
        let before = model.vocabularyGeneration
        model.refreshPersonalWordProtection()
        model.apply(KeyboardPreferences(autocorrectEnabled: true, swipeTypingEnabled: false))
        for _ in 0..<300 where !model.isCorrectorReady { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.isCorrectorReady)
        XCTAssertEqual(model.vocabularyGeneration - before, 1)
        proxy.hasOpenAccess = false
        model.refreshFullAccess()
    }

    func testExistingKeyboardReadsRestoredSpellingOnAppearance() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersonalVocabulary(fileURL: root.appendingPathComponent("words.json"))
        let p = Proxy()
        p.hasOpenAccess = true
        p.capitalizes = true
        p.text = "type "
        let model = KeyboardModel(proxy: p, vocabulary: { store })
        model.refreshTraits()
        model.refreshFullAccess()
        model.apply(KeyboardPreferences(autocorrectEnabled: true, swipeTypingEnabled: false))
        for _ in 0..<300 where !model.isCorrectorReady { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.isCorrectorReady)
        var backup = LibraryBackup(notes: [], dictations: [], meetings: [])
        backup.vocabulary = PersonalVocabulary.Document(words: ["QuillBerry"])
        let package = root.appendingPathComponent("Copy.zonebackup")
        try LibraryBackupFiles.write(backup, to: package, meetingDirectory: root)
        // Let the background read finish while its delivery is still waiting on this main
        // thread. A restore and appearance in this interval must supersede its old words.
        model.refreshPersonalWordProtection()
        KeyboardModel.vocabularyQueue.sync {}
        try store.restore(XCTUnwrap(LibraryBackupFiles.read(package).vocabulary))
        model.refreshPersonalWordProtection()
        for _ in 0..<300 where SpellingStore.current?.evaluate("quillberry").replacement != "QuillBerry" {
            try await Task.sleep(for: .milliseconds(20))
        }
        type("quillberry ", model)
        XCTAssertEqual(p.text, "type QuillBerry ")
        // Hosts requesting all lowercase still receive their preferred casing.
        p.capitalizes = false
        model.refreshTraits()
        type("quillberry ", model)
        XCTAssertEqual(p.text, "type QuillBerry quillberry ")
        p.hasOpenAccess = false
        model.refreshFullAccess()
    }

    func testASlipTypedOverADictatedWordIsCorrectedNotKept() async throws {
        let p = Proxy(), m = try await prepared(p)
        var fixes: [[String]] = []
        m.onWordCorrected = { fixes.append([$0, $1]) }
        dictate("that is defiantly", p, m)
        backspace(9, m)
        type("definitly ", m)
        XCTAssertEqual(p.text, "that is definitely ", "the slip is fixed by the space, as any typed word is")
        XCTAssertEqual(fixes, [["defiantly", "definitly"]], "the unsure-word check still hears of the hand fix")
    }

    func testAWordTypedOverWhatAutocorrectWouldWriteIsKept() async throws {
        let p = Proxy(), m = try await prepared(p)
        var fixes: [[String]] = []
        m.onWordCorrected = { fixes.append([$0, $1]) }
        dictate("on my frostbite", p, m)
        backspace(3, m)
        type("yte ", m)
        XCTAssertEqual(p.text, "on my frostbyte ", "the person refused frostbite, so frostbyte stands")
        XCTAssertEqual(fixes, [["frostbite", "frostbyte"]])
    }

    func testANameTypedWithAChosenCapitalIsKept() async throws {
        let p = Proxy(), m = try await prepared(p)
        dictate("we pay with bricks", p, m)
        backspace(6, m)
        m.handleTap(.shift)
        type("Brex ", m)
        XCTAssertEqual(p.text, "we pay with Brex ", "a capital the person chose marks a name, not a slip")
    }

    func testAnEditElsewhereIsNotAHandFix() async throws {
        let p = Proxy(), m = try await prepared(p)
        var fixes = 0
        m.onWordCorrected = { _, _ in fixes += 1 }
        dictate("sounds good", p, m)
        type(" thanks ", m)
        XCTAssertEqual(fixes, 0)
        XCTAssertEqual(p.text, "sounds good thanks ")
    }

    // MARK: A dictation taken back

    /// Undo of a dictation emptied the field and left Shift lowercase, so the next dictation or
    /// typed word started without its capital (simulator, 2026-11-20).
    func testShiftFollowsTheTextLeftWhenADictationIsTakenBack() async throws {
        let p = Proxy()
        p.capitalizes = true
        let m = try await prepared(p)
        m.refreshTraits()
        dictate("Sounds good", p, m)
        XCTAssertEqual(m.shift, .off, "mid-sentence after the dictation")
        p.text = ""
        m.dictationRemoved()
        XCTAssertEqual(m.shift, .on, "an emptied field starts with a capital again")
        XCTAssertEqual(m.dictationOpening, .capital, "and so does the next dictation")

        dictate("See you then. ", p, m)
        dictate("maybe", p, m)
        p.text = "See you then. "
        m.dictationRemoved()
        XCTAssertEqual(m.shift, .on, "after a finished sentence too")

        p.text = "See you"
        m.dictationRemoved()
        XCTAssertEqual(m.shift, .off, "and not in the middle of one")
    }
}
