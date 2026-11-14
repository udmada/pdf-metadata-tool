import Foundation

public enum DOIFinder {
    private struct Candidate {
        var doi: String
        var endsLine: Bool
    }

    /// Finds the paper's own DOI in the text of its first pages.
    public static func find(in pages: [String]) -> String? {
        let labelled = pages.map { candidates(in: $0, matching: #/(?i)(?:\bdoi\s*:?\s*|doi\.org/)(10\.\d{4,9}/[^\s"<>]+)/#) }
        // An unlabelled DOI is only trusted on the first page; further in, it is
        // most likely a cited reference.
        let unlabelled = pages.first.map { candidates(in: $0, matching: #/\b(10\.\d{4,9}/[^\s"<>]+)/#) } ?? []

        guard let best = labelled.first?.first ?? unlabelled.first ?? labelled.joined().first else { return nil }
        // A DOI that runs into the end of a line may have been cut by the line wrap;
        // the running header or footer usually prints it whole.
        if best.endsLine, let whole = labelled.joined().first(where: { $0.doi.count > best.doi.count && $0.doi.hasPrefix(best.doi) }) {
            return whole.doi
        }
        return best.doi
    }

    private static func candidates(in page: String, matching pattern: Regex<(Substring, Substring)>) -> [Candidate] {
        page.matches(of: pattern).map { match in
            let end = match.range.upperBound
            return Candidate(doi: clean(match.1), endsLine: end == page.endIndex || page[end].isNewline)
        }
    }

    private static func clean(_ raw: Substring) -> String {
        var doi = raw
        func trimPunctuation() {
            while let last = doi.last, ".,;:)]}'".contains(last) { doi.removeLast() }
        }
        trimPunctuation()
        // Preprint servers print "<doi>doi: bioRxiv preprint" with no space in between.
        if doi.lowercased().hasSuffix("doi") {
            doi.removeLast(3)
            trimPunctuation()
        }
        return String(doi)
    }
}
