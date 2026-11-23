// by zayd/cold @ zayd.wtf

import XCTest
import ZoneCore

@MainActor
final class DictationShiftTests: XCTestCase {
    typealias Proxy = SwipeIntegrationTests.Proxy

    private func model(_ proxy: Proxy, autoCaps: Bool = true, followsShift: Bool = true) -> KeyboardModel {
        let model = KeyboardModel(proxy: proxy)
        model.apply(KeyboardPreferences(autocorrectEnabled: false, hapticsEnabled: false,
            dictationFollowsShift: followsShift, autoCapitalizationEnabled: autoCaps))
        model.refreshTraits()
        return model
    }

    func testDisplayedLowercaseWinsWhenHostContextBecomesUnavailable() {
        let proxy = Proxy(); proxy.capitalizes = true; proxy.text = "already here "
        let model = model(proxy)
        defer { model.keyboardWillDisappear() }
        XCTAssertEqual(model.shift, .off)
        proxy.unknown = true
        XCTAssertEqual(TextStyle.casual.insertion(of: "Hello there", contextBefore: proxy.contextBefore(),
            fieldCapitalizesSentences: true, opening: model.dictationOpening), "hello there")
    }

    func testFollowingDictationSuppliesTheSpaceAfterSentencePunctuation() {
        let proxy = Proxy()
        proxy.capitalizes = true
        proxy.text = "Ready?"
        let model = model(proxy)
        defer { model.keyboardWillDisappear() }
        XCTAssertEqual(model.shift, .off)
        XCTAssertEqual(TextStyle.casual.insertion(of: "we are ready", contextBefore: proxy.text,
            fieldCapitalizesSentences: true, opening: model.dictationOpening), " We are ready")
    }

    func testAutoCapitalizationOffAndManualShiftAreIndependent() {
        let proxy = Proxy(); proxy.capitalizes = true
        let model = model(proxy, autoCaps: false)
        defer { model.keyboardWillDisappear() }
        XCTAssertEqual(model.dictationOpening, .lowercase)
        model.handleTap(.shift)
        XCTAssertEqual(model.dictationOpening, .capital)
        proxy.insert("Hello")
        model.dictationInserted("Hello")
        XCTAssertEqual(model.shift, .off)
        XCTAssertEqual(model.dictationOpening, .lowercase)
    }

    func testManualLowercaseSurvivesHostRefreshAndIsConsumedByInsertion() {
        let proxy = Proxy(); proxy.capitalizes = true
        let model = model(proxy)
        defer { model.keyboardWillDisappear() }
        XCTAssertEqual(model.shift, .on)
        model.handleTap(.shift)
        model.refreshTraits()
        XCTAssertEqual(model.dictationOpening, .lowercase)
        proxy.insert("hello. ")
        model.dictationInserted("hello. ")
        XCTAssertEqual(model.shift, .on)
    }

    func testCapsLockSurvivesDictationAndNewFieldClearsOneShotChoice() {
        let proxy = Proxy()
        let model = model(proxy)
        defer { model.keyboardWillDisappear() }
        model.handleTap(.shift); model.handleTap(.shift)
        XCTAssertEqual(model.shift, .locked)
        proxy.insert("Hello")
        model.dictationInserted("Hello")
        XCTAssertEqual(model.shift, .locked)
        // A locked Shift is its own opening since cd1edb9: the whole dictation in capitals.
        XCTAssertEqual(model.dictationOpening, .capsLock)
        // A separate instance exercises a one-shot Shift without double-tap timing.
        let next = self.model(proxy)
        defer { next.keyboardWillDisappear() }
        next.handleTap(.shift)
        XCTAssertEqual(next.dictationOpening, .capital)
        proxy.session = "another field"; proxy.text = ""
        next.refreshTraits()
        XCTAssertEqual(next.dictationOpening, .lowercase)
    }

    func testDisabledFollowShiftKeepsContextBasedFormatting() {
        let proxy = Proxy()
        let model = model(proxy, followsShift: false)
        defer { model.keyboardWillDisappear() }
        model.handleTap(.shift)
        XCTAssertEqual(model.dictationOpening, .automatic)
    }

    func testNumbersLayerUsesCurrentFieldWhenNoShiftKeyIsVisible() {
        let proxy = Proxy(); proxy.capitalizes = true; proxy.text = "mid sentence "
        let model = model(proxy)
        defer { model.keyboardWillDisappear() }
        model.handleTap(.switchLayer(.numbers, label: "123"))
        proxy.session = "empty field"; proxy.text = ""
        model.refreshTraits()
        XCTAssertEqual(TextStyle.casual.insertion(of: "hello", contextBefore: proxy.contextBefore(),
            fieldCapitalizesSentences: true, opening: model.dictationOpening), "Hello")
    }

    /// Retyping the last dictated word is learned when it is a name, a new word or other
    /// capitals; swapping one everyday word for another is rewording.
    func testOnlyMishearingsAreLearnedFromRetypedDictation() {
        func learnable(_ heard: String, _ written: String) -> Bool {
            KeyboardModel.isLearnableDictationFix(.init(heard: heard, written: written))
        }
        XCTAssertTrue(learnable("Versailles", "Vercel"))
        XCTAssertTrue(learnable("Zade", "Zayd"))
        XCTAssertTrue(learnable("chad", "chud"))
        XCTAssertTrue(learnable("openai", "OpenAI"))
        XCTAssertFalse(learnable("went", "go"))
        XCTAssertFalse(learnable("Hello", "hello"))
    }
}
