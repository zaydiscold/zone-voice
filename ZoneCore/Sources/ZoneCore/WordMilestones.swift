// by zayd/cold @ zayd.wtf

import Foundation

/// The short note Home shows when the running word count passes a mark: the number, one line
/// that puts it next to something familiar, and a way to tell Zayd how it is going.
///
/// It never asks for a rating. Apple's prompt does that on its own schedule (`ReviewPromptPolicy`),
/// and App Review Guideline 5.6.1 disallows a review prompt of our own.
public struct MilestoneNote: Equatable, Sendable {
    /// The mark that was passed, such as 10,000.
    public let mark: Int
    /// "10,000 words."
    public let title: String
    /// One line in Zayd's voice.
    public let line: String
}

public enum WordMilestones {
    /// Far enough apart that a note stays rare: days between the first two, weeks between the
    /// next, months later. 500 is the early check-in, when rough edges are freshest.
    public static let marks = [500, 1_000, 5_000, 10_000, 25_000, 50_000, 100_000, 250_000, 500_000, 1_000_000]

    /// Seconds an idle Home is on screen, at the start of a visit, before the note comes in.
    /// Longer than What's New's settle: the note is a card on the page, not a sheet, and it
    /// should land after the person has looked at Home, not race the first frame.
    public static let settle: TimeInterval = 2

    /// True when the note for `mark` may come up now. The same moment rules as What's New
    /// (`WhatsNewPolicy.mayPresent`: a visit the person began, Home in front and idle, nothing
    /// recording, typing, presented or in error, within the visit's opening seconds), plus:
    /// - the mark was passed before this visit began, so a dictation that crosses it never
    ///   drops a card onto the page under the words; the note waits for the next visit;
    /// - What's New is neither owed nor shown this visit, so one visit never carries both.
    public static func mayShow(mark: Int, moment: WhatsNewMoment, wordsAtVisitStart: Int,
                               whatsNewThisVisit: Bool) -> Bool {
        guard mark <= wordsAtVisitStart, !whatsNewThisVisit else { return false }
        return WhatsNewPolicy.mayPresent(moment) && moment.sinceOpened >= settle
    }

    /// The note owed for this word count, or nil. Only the highest mark passed is owed, so
    /// someone who updates at 30,000 words sees one note (25,000), not four in a row.
    /// - Parameter acknowledged: the highest mark whose note already came up. It is kept apart
    ///   from the word count, so starting the count over never brings an old note back.
    public static func pending(words: Int, acknowledged: Int) -> MilestoneNote? {
        guard let mark = marks.last(where: { $0 <= words }), mark > acknowledged else { return nil }
        return note(for: mark)
    }

    /// The note for a mark. Book lengths are the commonly cited counts, rounded, and agree with
    /// `WordScale`'s (Gatsby 47,094; War and Peace, Maude translation, about 563,000). The Old
    /// Man and the Sea is about 26,600, The Hobbit about 95,000 and Ulysses about 265,000.
    public static func note(for mark: Int) -> MilestoneNote {
        let line: String
        switch mark {
        case ..<1_000:
            line = "Your first 500. Early days are when the rough edges show, so tell me about them while they're fresh."
        case ..<5_000:
            line = "About four pages you never had to type. If anything annoyed you on the way here, I want to hear it."
        case ..<10_000:
            line = "That's a long magazine story, off the top of your head. What should Zone do better?"
        case ..<25_000:
            line = "Your thumbs would like to say thank you. I'd like to know what still gets in your way."
        case ..<50_000:
            line = "The Old Man and the Sea is about 27,000. You're nearly there, and you didn't need a boat."
        case ..<100_000:
            line = "The Great Gatsby is 47,000 words. You just talked your way past it."
        case ..<250_000:
            line = "That's The Hobbit, there and back again. Tell me what the next 100,000 should feel like."
        case ..<500_000:
            line = "Ulysses is 265,000, and yours probably makes more sense. What's still rough?"
        case ..<1_000_000:
            line = "War and Peace runs about 563,000 in English. You're closing in. Anything I should fix before you get there?"
        default:
            line = "A million. I built this after breaking my hand, and you've said more into it than I ever imagined. Thank you."
        }
        return MilestoneNote(mark: mark, title: "\(mark.formatted(.number.locale(Locale(identifier: "en_US")))) words.", line: line)
    }
}

/// The email Send feedback opens: the person's words, then one line about the app and phone
/// when they leave that on. Nothing is sent by Zone; the person's own mail app sends it.
public enum FeedbackEmail {
    public static let address = "zayd@zayd.wtf"

    public struct Details: Equatable, Sendable {
        public var appVersion: String
        public var build: String
        public var system: String
        public var device: String
        public var speechModel: String

        public init(appVersion: String, build: String, system: String, device: String, speechModel: String) {
            self.appVersion = appVersion
            self.build = build
            self.system = system
            self.device = device
            self.speechModel = speechModel
        }

        /// "Zone 1.0.5 (2026111801), iOS 26.1, iPhone17,1, Fluid Speech Mini". Empty parts drop out.
        public var line: String {
            let version = build.isEmpty ? appVersion : "\(appVersion) (\(build))"
            return (["Zone \(version)".trimmingCharacters(in: .whitespaces), system, device, speechModel] as [String])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        }
    }

    public static func subject(appVersion: String) -> String {
        let version = appVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        return version.isEmpty ? "Zone feedback" : "Zone feedback (\(version))"
    }

    /// The body: the message as written, then the details line when it is included.
    public static func body(message: String, details: Details?) -> String {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let details else { return message }
        return message.isEmpty ? details.line : "\(message)\n\n\(details.line)"
    }

    /// A `mailto:` link for the default mail app. Percent-encodes everything outside the ASCII
    /// unreserved set, so "&", "+", "?", line breaks, accents and emoji never cut it short or
    /// leave the link unreadable. (`CharacterSet.alphanumerics` would pass "é" through raw.)
    public static func mailto(message: String, details: Details?, appVersion: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let subject = subject(appVersion: appVersion).addingPercentEncoding(withAllowedCharacters: allowed),
              let body = body(message: message, details: details).addingPercentEncoding(withAllowedCharacters: allowed)
        else { return nil }
        return URL(string: "mailto:\(address)?subject=\(subject)&body=\(body)")
    }
}
