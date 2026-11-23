// by zayd/cold @ zayd.wtf

import Foundation

/// "See you soon smiley face" is ":)" in the texting styles.
///
/// Only the faces people say when they mean the characters, and only when the phrase is not the
/// thing being talked about: "draw a smiley face", "her sad face" and "smiley faces" stay words.
/// A list of faces reads one way, the way its first face does: "smiley face, sad face" sends both,
/// "a smiley face, sad face" names both. Three or more in a row are always sent. "Face down", "face first" and "face timing" are not faces.
/// A setting turns it off (`KeyboardPreferences.spokenEmoticons`).
enum SpokenEmoticons {
    static let faces: [(names: [String], emoticon: String)] = [
        (["smiley", "smiling", "smile", "happy"], ":)"),
        (["winky", "winking", "wink"], ";)"),
        (["sad", "frowny", "frowning", "frown", "unhappy"], ":("),
        (["crying", "cry"], ":'("),
        (["kissy", "kissing"], ":*"),
        (["tongue", "tongue out"], ":P"),
        (["laughing", "grinning"], ":D"),
        // The upside-down face is the smiley turned around (Zayd, November 16).
        (["upside down smiley", "upside down smiling", "upside down smile", "upside down"], "(:"),
    ]

    private static let table: [String: String] = Dictionary(
        uniqueKeysWithValues: faces.flatMap { face in face.names.map { ($0, face.emoticon) } })

    /// A word before the phrase that makes it a thing rather than a face being sent.
    private static let describing: Set<String> = [
        "a", "an", "the", "that", "this", "my", "your", "his", "her", "their", "our", "its", "one", "another", "little",
        "big", "no", "of", "with", "and", "or", "same", "every", "any", "some", "yellow", "giant", "huge", "tiny",
        "small", "cute", "called", "word", "words", "say", "says", "said", "saying", "type", "typed", "is", "was",
        "make", "makes", "made", "making", "pull", "pulls", "pulled", "pulling", "draw", "draws", "drew", "drawing",
    ]

    /// Words between two faces that keep them one list: "smiley face, sad face and winky face".
    private static let listJoins: Set<String> = ["and", "or", "then", "plus"]

    private static let expression: NSRegularExpression = {
        let names = table.keys.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: #"[ \t\-]+"#) }
            .joined(separator: "|")
        // The recognizer's own comma or period after the phrase belongs to the words, not the face.
        // "face down", "face first", "face up" and FaceTime are something else.
        return try! NSRegularExpression(
            pattern: #"(?<![\p{L}\p{N}_'’\-])("# + names + #")[ \t\-]+face(?![\p{L}\p{N}_'’\-])"#
                + #"(?![ \t]+(?:down|up|first|tim(?:e|es|ed|ing)|book)(?![\p{L}]))[.,]?"#,
            options: [.caseInsensitive])
    }()

    static func writing(_ text: String) -> String {
        guard text.range(of: "face", options: .caseInsensitive) != nil else { return text }
        let source = text as NSString
        // Runs of faces in a list, each face with whether it would be sent on its own.
        var runs: [[(range: NSRange, emoticon: String, sends: Bool)]] = []
        var previousEnd: Int?
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let name = source.substring(with: match.range(at: 1)).lowercased()
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "-" }).joined(separator: " ")
            guard let emoticon = table[name] else { continue }
            let before = source.substring(to: match.range.location)
                .split(whereSeparator: { $0.isWhitespace }).last?
                .trimmingCharacters(in: .punctuationCharacters).lowercased()
            let face = (range: match.range, emoticon: emoticon, sends: before.map { !describing.contains($0) } ?? true)
            if let previousEnd, !runs.isEmpty, Self.continuesList(source.substring(with: NSRange(location: previousEnd,
                                                                                         length: match.range.location - previousEnd))) {
                runs[runs.count - 1].append(face)
            } else {
                runs.append([face])
            }
            previousEnd = NSMaxRange(match.range)
        }
        // A list reads one way, the way its first face does. Three or more faces in a row are
        // the marks whatever comes before them: nobody describes "a smiley face, sad face,
        // winky face" in a message, but people test and list emoticons exactly that way.
        var edits: [(range: NSRange, emoticon: String)] = []
        for run in runs where run.count >= 3 || run[0].sends {
            edits += run.map { ($0.range, $0.emoticon) }
        }
        var out = text
        for edit in edits.reversed() {
            guard let range = Range(edit.range, in: out) else { continue }
            out.replaceSubrange(range, with: edit.emoticon)
        }
        return out
    }

    /// Only spaces, commas and a joining word between two faces.
    private static func continuesList(_ gap: String) -> Bool {
        gap.split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .allSatisfy { listJoins.contains($0.lowercased()) }
    }
}
