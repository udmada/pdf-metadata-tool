import Foundation

public enum TitleMatcher {
    /// Whether `title` (from a registry) is the title printed in `pageText`.
    /// Guards against a DOI that belongs to a cited reference rather than this paper.
    public static func matches(title: String, pageText: String) -> Bool {
        let squashedTitle = HTMLText.plain(title).squashed
        guard squashedTitle.count >= 8 else { return false }
        // Comparing without spaces or punctuation tolerates line wraps, quote styles
        // and PDFs whose text layer has no word spacing.
        if pageText.squashed.contains(squashedTitle) { return true }

        let titleWords = title.comparisonWords.filter { $0.count >= 4 }
        guard titleWords.count >= 3 else { return false }
        let pageWords = Set(pageText.comparisonWords)
        let hits = titleWords.count(where: pageWords.contains)
        return Double(hits) / Double(titleWords.count) >= 0.8
    }
}

public enum AuthorFormatter {
    /// Formats names as the single author string Books displays best.
    public static func format(_ authors: [String]) -> String? {
        switch authors.count {
        case 0: nil
        case 1: authors[0]
        case 2: "\(authors[0]) and \(authors[1])"
        case 3...5: authors.dropLast().joined(separator: ", ") + ", and \(authors[authors.count - 1])"
        default: authors.prefix(5).joined(separator: ", ") + ", et al."
        }
    }
}

public enum TitleExtractor {
    /// The title is taken to be the largest text on the first page that reads like a phrase.
    public static func title(from runs: [TextRun]) -> String? {
        var merged: [TextRun] = []
        for run in runs {
            if let last = merged.last, abs(last.fontSize - run.fontSize) < 0.25 {
                merged[merged.count - 1].text += run.text
            } else {
                merged.append(run)
            }
        }

        var best: (text: String, size: Double)?
        for run in merged {
            // A title set over two sizes leaves its first part ending in a colon or dash.
            let text = run.text.collapsingWhitespace.trimmingCharacters(in: CharacterSet(charactersIn: " :;,–—-"))
            guard (15...400).contains(text.count), text.split(separator: " ").count >= 3 else { continue }
            if best == nil || run.fontSize > best!.size {
                best = (text, run.fontSize)
            }
        }
        return best?.text
    }
}

public enum Boilerplate {
    private static let publishers = [
        "american medical association", "jama network", "elsevier", "springer", "wiley",
        "taylor & francis", "taylor and francis", "nature publishing", "biomed central", "bmc",
        "plos", "sage publications", "university press", "mdpi",
    ]

    /// Titles left behind by authoring tools and publisher pipelines rather than written by a person.
    public static func isJunkTitle(_ title: String) -> Bool {
        let lower = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty { return true }
        if ["untitled", "microsoft word", "pii:", "doi:", "10."].contains(where: lower.hasPrefix) { return true }
        if lower.contains(#/\.(pdf|docx?|indd|dvi|tex|qxd)$/#) { return true }
        // A long string without spaces is a filename, an identifier, or text with lost word spacing.
        return lower.count > 20 && !lower.contains(" ")
    }

    public static func isPublisherAuthor(_ author: String) -> Bool {
        let lower = author.lowercased()
        return (publishers + ["journal", "open access", "international publisher"]).contains(where: lower.contains)
    }

    public static func isPublisherKeyword(_ keyword: String) -> Bool {
        let lower = keyword.lowercased()
        return publishers.contains(where: lower.contains)
    }

    /// Signs that something other than keywords was captured into the keywords field:
    /// a DOI, a citation bracket, a volume(issue) reference, or a sentence break from body text.
    public static func keywordsLookCorrupted(_ keywords: [String]) -> Bool {
        keywords.contains { keyword in
            keyword.contains(#/10\.\d{4,}//#) || keyword.contains(#/\[\d/#) || keyword.contains(#/\d\(\d+\)/#) || keyword.contains(#/[a-z]{2,}\.\s+[a-z]/#)
        }
    }
}
