// by zayd/cold @ zayd.wtf

import Foundation
import XCTest

/// Checks that read the app's own source, for agreements no single screen can test: a name iOS
/// shows for a control is the name Zone's help uses, and every error reads in the theme's red.
/// Found by the cohesion audit of 2026-11-20 (`docs/research/2026-11-20-cohesion-audit.md`).
final class AppCohesionTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    private func matches(_ pattern: String, in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    private func swiftFiles(under folder: String) -> [URL] {
        let base = Self.root.appendingPathComponent(folder)
        let found = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        return (found?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    func testHomeSectionBreaksStayOffTheRowGrid() throws {
        for name in ["HomeView", "HomeLibraryView"] {
            let file = try source("Zone/Views/\(name).swift")
            // The recovery list is a separate view in this file. Within that list, sibling
            // recordings use row rules. Only the outer Home groups use open paper.
            let home = file.components(separatedBy: "struct HomeAudioRecoverySection: View").first ?? file
            let rowOrPanelRule = #"\b(RowRule|PanelEdge|Hairline|Divider)\s*\("#
            XCTAssertEqual(matches(rowOrPanelRule, in: home), [], "\(name) separates groups with open paper")
            XCTAssertTrue(home.contains("SectionBreak"), "\(name) uses the shared group spacing")
        }
    }

    /// Notes, History and So far each open with the same bold title, so the three groups on Home
    /// announce themselves alike.
    func testHomeSectionTitlesMatch() throws {
        let library = try source("Zone/Views/HomeLibraryView.swift")
        let home = try source("Zone/Views/HomeView.swift")
        for (title, file) in [("Notes", library), ("History", library), ("So far", home)] {
            XCTAssertTrue(file.contains("Text(\"\(title)\").font(.headline)"), "\(title) uses the Home section title")
        }
        XCTAssertFalse(home.contains("Eyebrow(\"So far\")"), "So far is a section title, not a small label")
    }

    /// The row names the help page lists: the first string of each `("Name", "Detail")` pair.
    private func helpRowNames() throws -> Set<String> {
        Set(matches(#"\(\s*"([^"]+)",\s*""#, in: try source("Zone/Views/ShortcutHelpView.swift")))
    }

    /// Settings opens the page by a row; the page's title must be the same words. They were
    /// "Action Button and Shortcuts" and "Action Button & Shortcuts". Both now pick the name by
    /// device (phones without an Action Button get "Shortcuts and Back Tap"), so the row and the
    /// title are compared as whole expressions: same condition, same two titles, same order.
    func testTheHelpPageIsTitledLikeItsSettingsRow() throws {
        // One argument: a string literal or an expression of literals, with no parentheses.
        let argument = #"((?:"[^"]*"|[^"()])+)"#
        let settings = try source("Zone/Views/SettingsView.swift")
        let rows = matches(#"NavigationLink\("# + argument + #"\)\s*\{\s*ShortcutHelpView\(\)"#, in: settings)
        let titles = matches(#"\.navigationTitle\("# + argument + #"\)"#, in: try source("Zone/Views/ShortcutHelpView.swift"))
        XCTAssertEqual(rows.count, 1, "Settings opens the help page from one row")
        let squashed = { (code: String) in code.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        XCTAssertEqual(titles.map(squashed), rows.map(squashed))
        let literals = { (code: String) in self.matches(#""([^"]*)""#, in: code) }
        for (expression, place) in [(rows.first ?? "", "Settings row"), (titles.first ?? "", "help page title")] {
            XCTAssertEqual(literals(expression), ["Action Button and Shortcuts", "Shortcuts and Back Tap"],
                           "The \(place) names the page for both kinds of iPhone: \(expression)")
            XCTAssertTrue(expression.contains("SetupDevice.hasActionButton"), "The \(place) picks its name by device")
        }
    }

    /// Each control Zone offers the Action Button, Control Center and the Lock Screen has a line
    /// on the help page under the name iOS shows. The page had lost Toggle Zone and Bring back
    /// Zone's island.
    func testTheHelpPageNamesEveryControl() throws {
        let controls = matches(#"\.displayName\("([^"]+)"\)"#, in: try source("ZoneActivity/ZoneControls.swift"))
        XCTAssertFalse(controls.isEmpty)
        let rows = try helpRowNames()
        for control in controls {
            XCTAssertTrue(rows.contains(control), "The help page has no line for the control \"\(control)\"")
        }
    }

    /// Each shortcut a person can find in the Shortcuts app (an `AppIntent` or Focus filter that
    /// is not hidden with `isDiscoverable = false`) is named on the help page. Voice note and
    /// Dictate and copy are named once, under Controls.
    func testTheHelpPageNamesEveryShortcut() throws {
        var titles: [String] = []
        for file in swiftFiles(under: "Shared") + swiftFiles(under: "Zone") {
            let text = try String(contentsOf: file, encoding: .utf8)
            for block in text.components(separatedBy: "\nstruct ").dropFirst() {
                let header = block.prefix { $0 != "{" }
                guard header.contains("AppIntent") || header.contains("SetFocusFilterIntent"),
                      !block.contains("isDiscoverable = false"),
                      let title = matches(#"static (?:let|var) title: LocalizedStringResource = "([^"]+)""#, in: block).first
                else { continue }
                titles.append(title)
            }
        }
        XCTAssertTrue(titles.contains("Get last dictation"), "found \(titles)")
        let page = try source("Zone/Views/ShortcutHelpView.swift")
        let rows = try helpRowNames()
        for title in titles {
            XCTAssertTrue(rows.contains(title) || page.contains(title),
                          "The help page never names the shortcut \"\(title)\"")
        }
    }

    /// Errors read in `Zone.live`, the theme's one red. Three screens (Computers, Send text and
    /// Backup and export) used the system red, which is a different, harsher color.
    func testErrorsUseTheThemeRed() throws {
        let systemRed = [".foregroundStyle(.red)", "Color.red", ".tint(.red)"]
        var offenders: [String] = []
        for file in swiftFiles(under: "Zone") where !file.path.contains("/Diagnostics/") {
            if file.lastPathComponent == "DiagnosticsView.swift" { continue }  // debug builds only
            let text = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in text.components(separatedBy: "\n").enumerated()
            where systemRed.contains(where: line.contains) {
                offenders.append("\(file.lastPathComponent):\(number + 1)")
            }
        }
        XCTAssertEqual(offenders, [])
    }
}
