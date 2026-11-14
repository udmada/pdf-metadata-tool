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
