// by zayd/cold @ zayd.wtf

import Foundation

/// Byte-level BPE for the pinned LFM2 tokenizer. User text is never parsed as chat control tokens.
public struct CleanupTokenizer {
  private let vocabulary: [String: Int]
  private let reverse: [Int: String]
  private let ranks: [String: Int]
  private let byteSymbols: [String]
  private let symbolBytes: [Unicode.Scalar: UInt8]
  private let expression: NSRegularExpression

  public init(data: Data) throws {
    struct Document: Decodable {
      struct Model: Decodable {
        let vocab: [String: Int]
        let merges: [[String]]
      }
      let model: Model
    }
    let doc = try JSONDecoder().decode(Document.self, from: data)
    vocabulary = doc.model.vocab
    var reverseVocabulary: [Int: String] = [:]
    for (token, id) in vocabulary {
      guard reverseVocabulary.updateValue(token, forKey: id) == nil else {
        throw CocoaError(.fileReadCorruptFile)
      }
    }
    reverse = reverseVocabulary
    var rank: [String: Int] = [:]
    for (index, pair) in doc.model.merges.enumerated() where pair.count == 2 {
      rank[pair[0] + "\0" + pair[1]] = index
    }
    ranks = rank
    var bytes = Array(33...126) + Array(161...172) + Array(174...255)
    var scalars = bytes
    var extra = 0
    for byte in 0...255 where !bytes.contains(byte) {
      bytes.append(byte)
      scalars.append(256 + extra)
      extra += 1
    }
    var symbols = Array(repeating: "", count: 256)
    var inverse: [Unicode.Scalar: UInt8] = [:]
    for (byte, scalar) in zip(bytes, scalars) {
      let value = Unicode.Scalar(scalar)!
      symbols[byte] = String(value)
      inverse[value] = UInt8(byte)
    }
    byteSymbols = symbols
    symbolBytes = inverse
    expression = try NSRegularExpression(
      pattern:
        #"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}{1,3}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+"#
    )
  }

  public func encode(_ text: String) throws -> [Int] {
    var result: [Int] = []
    for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
      guard let range = Range(match.range, in: text) else { continue }
      var pieces = text[range].utf8.map { byteSymbols[Int($0)] }
      while pieces.count > 1 {
        var best: (index: Int, rank: Int)?
        for i in 0..<(pieces.count - 1) {
          if let rank = ranks[pieces[i] + "\0" + pieces[i + 1]], rank < (best?.rank ?? Int.max) {
            best = (i, rank)
          }
        }
        guard let best else { break }
        let combined = pieces[best.index] + pieces[best.index + 1]
        pieces.remove(at: best.index + 1)
        pieces[best.index] = combined
      }
      for piece in pieces {
        guard let id = vocabulary[piece] else { throw CocoaError(.fileReadCorruptFile) }
        result.append(id)
      }
    }
    return result
  }

  public func decode(_ tokens: [Int]) throws -> String {
    var bytes: [UInt8] = []
    for token in tokens {
      guard let text = reverse[token] else { throw CocoaError(.fileReadCorruptFile) }
      for scalar in text.unicodeScalars {
        guard let byte = symbolBytes[scalar] else { throw CocoaError(.fileReadCorruptFile) }
        bytes.append(byte)
      }
    }
    return String(decoding: bytes, as: UTF8.self)
  }

  public func prompt(for text: String) throws -> [Int] {
    var result = [1, 6]
    result += try encode(
      "system\nYou edit a transcript, never answer it. Fix punctuation and capitalization. Remove only um and uh fillers. Preserve every other word, names, numbers, negations and spoken corrections. Return only the edited transcript."
    )
    result += [7]
    result += try encode("\n")
    result += [6]
    result += try encode("user\n" + text)
    result += [7]
    result += try encode("\n")
    result += [6]
    result += try encode("assistant\n")
    return result
  }
}
