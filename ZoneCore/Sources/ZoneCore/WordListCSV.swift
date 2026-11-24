// by zayd/cold @ zayd.wtf

import Foundation

/// Editable dictionary interchange. Unheaded pairs use the Wispr order, heard then written.
/// Zone exports an explicit header so the optional heard-as column can come second.
public enum WordListCSV {
    public enum ImportError: LocalizedError {
        case empty, row(Int), tooLarge, encoding
        public var errorDescription: String? {
            switch self {
            case .empty: return "Add at least one word to import."
            case .row(let line): return "Check line \(line). Use one word, a correction pair, or the columns in the header. A source must be added or learned."
            case .tooLarge: return "Split the list into files smaller than 3 MB."
            case .encoding: return "Save the list as UTF-8 text or CSV."
            }
        }
    }
    public static let byteLimit = 3_000_000

    public static func read(_ text: String) throws -> PersonalVocabulary.Document {
        guard text.utf8.count <= byteLimit else { throw ImportError.tooLarge }
        var result = PersonalVocabulary.Document(words: [])
        var first = true
        var wordFirst = false
        var hasSource = false
        var origins: [String: Bool] = [:]
        let text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}"))
        for (index, line) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            if line.allSatisfy(\.isWhitespace) { continue }
            let fields = try fields(line, number: index + 1)
            if first {
                first = false
                let names = fields.map { $0.lowercased() }
                if names == ["word", "heard as", "source"] { wordFirst = true; hasSource = true; continue }
                if names == ["word", "heard as"] { wordFirst = true; continue }
                if names == ["misspelling", "correction"] || names == ["word", "replacement"] { continue }
            }
            guard hasSource ? fields.count == 3 : fields.count <= 2 else { throw ImportError.row(index + 1) }
            let second = fields.count >= 2 ? fields[1] : ""
            let reversed = !wordFirst && !second.isEmpty
            let word = reversed ? second : fields[0]
            let heard = (reversed ? fields[0] : second).lowercased()
            guard !word.isEmpty else { throw ImportError.row(index + 1) }
            if hasSource {
                let source = fields[2].lowercased()
                let learned = source == "learned"
                let key = word.lowercased()
                guard learned || source == "added", origins[key].map({ $0 == learned }) ?? true else {
                    throw ImportError.row(index + 1)
                }
                if learned && origins[key] == nil { result.learned.append(key) }
                origins[key] = learned
            }
            result.words.append(word)
            if !heard.isEmpty && heard != word.lowercased() {
                if let other = result.misheard[heard], other.lowercased() != word.lowercased() {
                    throw ImportError.row(index + 1)
                }
                result.misheard[heard] = word
            }
        }
        result.words = PersonalVocabulary.normalized(result.words)
        guard !result.words.isEmpty else { throw ImportError.empty }
        return result
    }

    private static func fields(_ line: Substring, number: Int) throws -> [String] {
        var parts: [String] = [], value = ""
        var quoted = false, closed = false
        var chars = line.makeIterator()
        while let c = chars.next() {
            if quoted {
                if c == "\"" { quoted = false; closed = true } else { value.append(c) }
            } else if c == "," {
                parts.append(value.trimmingCharacters(in: .whitespaces))
                value = ""; closed = false
            } else if c == "\"", closed || value.isEmpty {
                if closed { value.append(c) }
                quoted = true; closed = false
            } else if closed {
                if !c.isWhitespace { throw ImportError.row(number) }
            } else { value.append(c) }
        }
        guard !quoted else { throw ImportError.row(number) }
        parts.append(value.trimmingCharacters(in: .whitespaces))
        return parts
    }

    public static func write(_ document: PersonalVocabulary.Document) -> String {
        let pairs = Dictionary(grouping: document.misheard, by: { $0.value.lowercased() })
        let learned = Set(document.learned.map { $0.lowercased() })
        var rows = [learned.isEmpty ? "word,heard as" : "word,heard as,source"]
        for word in document.words {
            let source = learned.isEmpty ? "" : (learned.contains(word.lowercased()) ? ",learned" : ",added")
            let aliases = pairs[word.lowercased()]?.map(\.key).sorted() ?? []
            for alias in aliases.isEmpty ? [""] : aliases {
                rows.append(quote(word) + "," + quote(alias) + source)
            }
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private static func quote(_ field: String) -> String {
        "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
