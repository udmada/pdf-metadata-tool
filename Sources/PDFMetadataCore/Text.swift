import Foundation

extension String {
    var collapsingWhitespace: String {
        // Soft hyphens mark optional line-break points and are not part of the word.
        replacing("\u{00AD}", with: "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Lowercased letters and digits only, diacritics folded: for comparing text that may differ
    /// in spacing, punctuation or quote style.
    var squashed: String {
        String(String.UnicodeScalarView(foldedForComparison.unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
    }

    var comparisonWords: [String] {
        foldedForComparison.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private var foldedForComparison: String {
        folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }
}

public enum HTMLText {
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "–", "mdash": "—", "hellip": "…",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
    ]

    /// Strips markup tags and decodes character entities, as found in CrossRef and publisher titles.
    public static func plain(_ s: String) -> String {
        s.replacing(#/</?[A-Za-z][^>]*>/#, with: "")
            .replacing(#/&(#[xX][0-9A-Fa-f]+|#[0-9]+|[A-Za-z]+);/#) { match -> String in
                let entity = match.1
                if entity.hasPrefix("#") {
                    let isHex = entity.dropFirst().first?.lowercased() == "x"
                    let digits = entity.dropFirst(isHex ? 2 : 1)
                    guard let code = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(code) else {
                        return String(match.0)
                    }
                    return String(scalar)
                }
                return namedEntities[String(entity)] ?? String(match.0)
            }
            .collapsingWhitespace
    }
}

extension HTMLText {
    private static let ligatures = ["ffi", "ffl", "fi", "fl", "ff"]

    /// Rejoins words that PDFKit split where a font's "fi" or "fl" ligature glyph came out as a space
    /// ("immunode ciency"). A pair is joined only when the whole word appears in `vocabulary`,
    /// typically the lowercased words of the same page, where the body text usually spells it out.
    public static func rejoiningLigatures(_ text: String, vocabulary: Set<String>) -> String {
        var tokens = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var index = 0
        while index + 1 < tokens.count {
            let (left, right) = (tokens[index], tokens[index + 1])
            let leftCore = String(left.reversed().prefix(while: \.isLetter).reversed()).lowercased()
            let rightCore = String(right.prefix(while: \.isLetter)).lowercased()
            if !leftCore.isEmpty, !rightCore.isEmpty,
               let ligature = ligatures.first(where: { vocabulary.contains(leftCore + $0 + rightCore) }) {
                tokens[index] = left + ligature + right
                tokens.remove(at: index + 1)
            } else {
                index += 1
            }
        }
        return tokens.joined(separator: " ")
    }

    /// The lowercased words of `text`, for [rejoiningLigatures(_:vocabulary:)].
    public static func vocabulary(of text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
    }
}
