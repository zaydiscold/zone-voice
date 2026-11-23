// by zayd/cold @ zayd.wtf

import XCTest
@testable import ZoneCore

final class EmojiCatalogTests: XCTestCase {
    // MARK: The bundled catalog

    func testBundledCatalogHasApplesCategoriesInApplesOrder() throws {
        let catalog = try XCTUnwrap(EmojiCatalog.loadBundled())
        XCTAssertEqual(catalog.categories.map(\.name), [
            "Smileys & People", "Animals & Nature", "Food & Drink", "Activity",
            "Travel & Places", "Objects", "Symbols", "Flags",
        ])
        let count = catalog.categories.reduce(0) { $0 + $1.emoji.count }
        XCTAssertGreaterThan(count, 1_800)
        XCTAssertEqual(catalog.categories.first?.emoji.first?.text, "😀")
        XCTAssertTrue(catalog.categories.allSatisfy { !$0.emoji.isEmpty })
    }

    func testBundledCatalogLeavesOutBareSkinTonesAndToneVariantsAsBases() throws {
        let catalog = try XCTUnwrap(EmojiCatalog.loadBundled())
        let bases = Set(catalog.categories.flatMap { $0.emoji.map(\.text) })
        XCTAssertFalse(bases.contains("🏻"), "Components are not typed alone")
        XCTAssertFalse(bases.contains("👋🏽"), "Skin tones live under their base")
        XCTAssertEqual(bases.count, catalog.categories.reduce(0) { $0 + $1.emoji.count }, "No emoji twice")
    }

    func testBundledCatalogKeepsUniformSkinTonesLightToDark() throws {
        let catalog = try XCTUnwrap(EmojiCatalog.loadBundled())
        let all = catalog.categories.flatMap(\.emoji)
        let wave = try XCTUnwrap(all.first { $0.text == "👋" })
        XCTAssertEqual(wave.tones.map(\.text), ["👋🏻", "👋🏼", "👋🏽", "👋🏾", "👋🏿"])
        // A two-person emoji keeps only the five single-tone pairs.
        let pair = try XCTUnwrap(all.first { $0.text == "🧑‍🤝‍🧑" })
        XCTAssertEqual(pair.tones.count, 5)
        XCTAssertEqual(pair.tones.first?.text, "🧑🏻‍🤝‍🧑🏻")
        // Handshake's tones arrived years after the handshake.
        let handshake = try XCTUnwrap(all.first { $0.text == "🤝" })
        XCTAssertEqual(handshake.version, 3.0)
        XCTAssertEqual(handshake.tones.first?.version, 14.0)
        // Index finger pointing up is fully qualified with FE0F; its tones are not.
        XCTAssertEqual(all.first { $0.text == "☝️" }?.tones.first?.text, "☝🏻")
        XCTAssertTrue(all.first { $0.text == "😀" }?.tones.isEmpty ?? false)
    }

    // MARK: Parsing

    func testParsesCategoriesVersionsAndTones() throws {
        let catalog = try XCTUnwrap(EmojiCatalog(tsv: """
        # comment
        @Smileys & People
        1.0\t😀
        0.6\t👋\t1.0:👋🏻 1.0:👋🏼 1.0:👋🏽 1.0:👋🏾 1.0:👋🏿
        @Flags
        2.0\t🇨🇦
        """))
        XCTAssertEqual(catalog.categories.map(\.name), ["Smileys & People", "Flags"])
        XCTAssertEqual(catalog.categories[0].emoji[1].version, 0.6)
        XCTAssertEqual(catalog.categories[0].emoji[1].tones.last, Emoji.Tone(text: "👋🏿", version: 1.0))
        XCTAssertEqual(catalog.categories[1].emoji, [Emoji(text: "🇨🇦", version: 2.0)])
    }

    func testRejectsMalformedResources() {
        XCTAssertNil(EmojiCatalog(tsv: ""))
        XCTAssertNil(EmojiCatalog(tsv: "1.0\t😀"), "An emoji before any category")
        XCTAssertNil(EmojiCatalog(tsv: "@A\nnew\t😀"), "A version that is not a number")
        XCTAssertNil(EmojiCatalog(tsv: "@A\n1.0\t👋\t1.0:👋🏻 1.0:👋🏼"), "Two tones instead of five")
        XCTAssertNil(EmojiCatalog(tsv: "@A\n1.0\t"), "No emoji")
    }

    // MARK: Drawable filter

    func testDrawableAsksOnlyAboutEmojiNewerThanIOS17AndDropsWhatItRejects() throws {
        let catalog = try XCTUnwrap(EmojiCatalog(tsv: """
        @A
        1.0\t😀
        16.0\t🫩
        3.0\t🤝\t14.0:🤝🏻 14.0:🤝🏼 14.0:🤝🏽 14.0:🤝🏾 14.0:🤝🏿
        15.0\t🫨
        15.1\t🙂‍↔️
        12.0\t🧑‍🤝‍🧑\t12.0:a 12.0:b 12.0:c 18.0:d 12.0:e
        """))
        var asked: [String] = []
        let drawn = catalog.drawable { text in
            asked.append(text)
            return text != "🫩" && text != "d"
        }
        XCTAssertEqual(asked, ["🫩", "🙂‍↔️", "d"])
        XCTAssertEqual(drawn.categories[0].emoji.map(\.text), ["😀", "🤝", "🫨", "🙂‍↔️", "🧑‍🤝‍🧑"])
        XCTAssertEqual(drawn.categories[0].emoji[1].tones.count, 5)
        XCTAssertTrue(drawn.categories[0].emoji[4].tones.isEmpty, "One undrawable tone hides all five")
    }

    func testBaseIndexMapsTonesToTheirBase() throws {
        let catalog = try XCTUnwrap(EmojiCatalog.loadBundled())
        let index = catalog.baseIndex()
        XCTAssertEqual(index["👋🏾"], "👋")
        XCTAssertEqual(index["👋"], "👋")
        XCTAssertNil(index["a"])
    }

    // MARK: History

    func testRecentsAreNewestFirstWithoutRepeatsAndCapped() {
        var history = EmojiHistory()
        history.use("😀", base: nil)
        history.use("🔥", base: nil)
        history.use("😀", base: nil)
        XCTAssertEqual(history.recents, ["😀", "🔥"])
        for i in 0..<40 { history.use("x\(i)", base: nil) }
        XCTAssertEqual(history.recents.count, EmojiHistory.recentLimit)
        XCTAssertEqual(history.recents.first, "x39")
    }

    func testTonesAreRememberedPerBaseAndClearedByThePlainOne() {
        let wave = Emoji(text: "👋", version: 0.6, tones: ["👋🏻", "👋🏼", "👋🏽", "👋🏾", "👋🏿"].map { Emoji.Tone(text: $0, version: 1) })
        var history = EmojiHistory()
        XCTAssertEqual(history.shown(wave), "👋")
        history.use("👋🏽", base: "👋")
        XCTAssertEqual(history.shown(wave), "👋🏽")
        XCTAssertEqual(history.recents, ["👋🏽"])
        history.use("👋", base: "👋")
        XCTAssertEqual(history.shown(wave), "👋")
        XCTAssertTrue(history.tones.isEmpty)
        // A remembered tone the catalog no longer offers falls back to the base.
        let plain = Emoji(text: "👋", version: 0.6)
        history.use("👋🏿", base: "👋")
        XCTAssertEqual(history.shown(plain), "👋")
    }

    func testRecentsInIndexDropsEmojiTheCatalogNoLongerOffers() {
        let history = EmojiHistory(recents: ["😀", "🫩", "👋🏽"])
        XCTAssertEqual(history.recents(in: ["😀": "😀", "👋🏽": "👋"]), ["😀", "👋🏽"])
    }

    func testHistoryDecodesFieldByField() throws {
        let decoded = try JSONDecoder().decode(EmojiHistory.self, from: Data(#"{"recents":["😀"],"tones":7}"#.utf8))
        XCTAssertEqual(decoded, EmojiHistory(recents: ["😀"]))
        let roundTrip = EmojiHistory(recents: ["👋🏽"], tones: ["👋": "👋🏽"])
        XCTAssertEqual(try JSONDecoder().decode(EmojiHistory.self, from: JSONEncoder().encode(roundTrip)), roundTrip)
    }

    // MARK: Preference

    func testEmojiKeyIsOffByDefaultAndOlderRecordsKeepItOff() throws {
        XCTAssertFalse(KeyboardPreferences().showsEmojiKey)
        let old = try JSONDecoder().decode(KeyboardPreferences.self, from: Data(#"{"showsPasteKey":true}"#.utf8))
        XCTAssertTrue(old.showsPasteKey)
        XCTAssertFalse(old.showsEmojiKey)
        let on = KeyboardPreferences(showsEmojiKey: true)
        XCTAssertEqual(try JSONDecoder().decode(KeyboardPreferences.self, from: JSONEncoder().encode(on)), on)
    }
}
