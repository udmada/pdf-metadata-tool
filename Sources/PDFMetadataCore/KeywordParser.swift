import Foundation

public enum KeywordParser {
    /// Extracts keywords from a paper's explicit "Keywords" section; never guesses without one.
    public static func keywords(in pageText: String) -> [String] {
        let vocabulary = HTMLText.vocabulary(of: pageText)
        let pageText = HTMLText.rejoiningLigatures(pageText, vocabulary: vocabulary)
        let lines = pageText.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        for (index, line) in lines.enumerated() {
            guard let match = line.wholeMatch(of: #/(?i)(key\s?words?)\s*([:;.—–-])?\s*(.*)/#) else { continue }
            let (label, separator, rest) = (match.1, match.2, String(match.3))
            // "Keywords are..." is a sentence, not a section label.
            guard separator != nil || rest.isEmpty || label == label.uppercased() else { continue }

            var text = rest
            var next = index + 1
            if text.isEmpty {
                while next < lines.count, lines[next].isEmpty { next += 1 }
                guard next < lines.count else { return [] }
                if separators(in: lines[next]) == nil {
                    return tidy(onePerLine(lines[next...]))
                }
                text = lines[next]
                next += 1
            }

            // Follow a list that wraps onto the next few lines.
            let limit = next + 3
            while next < lines.count, next < limit, !text.hasSuffix(".") {
                let candidate = lines[next]
                guard !candidate.isEmpty, !isSectionStart(candidate) else { break }
                let listIsOpen = text.hasSuffix(",") || text.hasSuffix(";")
                let continuesPhrase = candidate.first?.isLowercase == true && candidate.count < 80
                let sameStyle = candidate.count < 80 && separators(in: text) != nil && separators(in: text) == separators(in: candidate)
                guard listIsOpen || continuesPhrase || sameStyle else { break }
                // A break after a hyphen ("non-" / "heterosexual") or before a symbol that ends an
                // acronym ("LGBTQI" / "+") is inside a keyword, not between words.
                let gluesOn = text.hasSuffix("-") || candidate.first.map { "+þ".contains($0) } == true
                // A word hyphenated only to break the line ("sub-" / "stance") loses the hyphen
                // when the page spells it whole elsewhere, plural included; compounds ("non-heterosexual") keep it.
                let brokenStem = String(text.dropLast().reversed().prefix(while: \.isLetter).reversed())
                let rest = String(candidate.prefix(while: \.isLetter))
                if text.hasSuffix("-"), !brokenStem.isEmpty, !rest.isEmpty, ["", "s", "es"].contains(where: { vocabulary.contains((brokenStem + rest).lowercased() + $0) }) {
                    text.removeLast()
                }
                text += (gluesOn ? "" : " ") + candidate
                next += 1
            }
            // Some publisher fonts map "+" to the glyph for "þ"; after a capital it can only be a plus ("LGBTQþ").
            return tidy(split(text.replacing(#/(\p{Lu})\s*þ(?!\p{L})/#) { "\($0.1)+" }))
        }
        return []
    }

    /// Splits a keyword list on whichever separator it uses, most specific first.
    public static func split(_ raw: String) -> [String] {
        let parts = separators(in: raw).map { raw.split(whereSeparator: $0.contains).map(String.init) } ?? [raw]
        return parts
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n.,;·•")) }
            .filter { !$0.isEmpty }
    }

    /// Drops non-keywords and case-insensitive duplicates.
    static func tidy(_ keywords: [String]) -> [String] {
        var seen: Set<String> = []
        return keywords
            .map(\.collapsingWhitespace)
            .filter { (2..<60).contains($0.count) && Int($0) == nil && seen.insert($0.lowercased()).inserted }
            .prefix(10)
            .map { $0 }
    }

    private static func separators(in text: String) -> Set<Character>? {
        // U+037E is the Greek question mark, which some typesetters use as a semicolon.
        let styles: [Set<Character>] = [[";", "\u{037E}"], ["|"], [","], ["·", "•"]]
        return styles.first { !$0.isDisjoint(with: text) }
    }

    private static func onePerLine(_ lines: ArraySlice<String>) -> [String] {
        Array(lines.prefix { line in
            !line.isEmpty && !isSectionStart(line) && line.count <= 40 && !line.hasSuffix(".")
                && line.split(separator: " ").count <= 5
        })
    }

    private static func isSectionStart(_ line: String) -> Bool {
        line.contains(#/(?i)^(abstract|introduction|background|methods?|results|conclusions?|received|accepted|published|correspondence|copyright|©|\d+\.?\s+introduction)\b/#)
            || line.contains(#/(?i)university|institute/#)
    }
}
