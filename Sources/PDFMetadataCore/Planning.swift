import Foundation

public enum FilenameBuilder {
    static let maxLength = 200

    /// A filesystem-safe "<title>.pdf", or nil when there is no usable title.
    public static func filename(forTitle title: String?) -> String? {
        guard let title else { return nil }
        var name = HTMLText.plain(title)
            // Finder shows ":" as "/", so titles keep their shape with a dash instead.
            .replacing(":", with: " -")
            .replacing(#/[<>"/\\|?*]/#, with: "")
            .replacing(#/[\x{00}-\x{1F}\x{7F}-\x{9F}]/#, with: "")
            .collapsingWhitespace
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        guard !name.isEmpty else { return nil }

        let maxBase = maxLength - ".pdf".count
        if name.count > maxBase {
            var cut = name.prefix(maxBase - 3)
            if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > maxBase * 7 / 10 {
                cut = cut[..<space]
            }
            name = cut + "..."
        }
        return name + ".pdf"
    }
}

public struct MetadataResolver: Sendable {
    private let lookup: (any DOILookup)?

    /// - Parameter lookup: registry used to confirm metadata by DOI; nil resolves offline.
    public init(lookup: (any DOILookup)?) {
        self.lookup = lookup
    }

    public func resolve(_ snapshot: PDFSnapshot) async -> ResolvedMetadata {
        var resolved = ResolvedMetadata()
        var doi = DOIFinder.find(in: snapshot.pageTexts)
        var work: CrossRefWork?

        if let lookup, let found = doi {
            do {
                var candidate = try await lookup.lookup(doi: found)
                // Text layers without word spacing run the next word into the DOI ("...150645orvia").
                let unglued = found.replacing(#/(\d)[A-Za-z]+$/#) { String($0.1) }
                if candidate == nil, unglued != found, let retried = try await lookup.lookup(doi: unglued) {
                    (candidate, doi) = (retried, unglued)
                }
                if let candidate {
                    // Only trust the registry once its title is seen printed in the paper.
                    if TitleMatcher.matches(title: candidate.title, pageText: snapshot.pageTexts.joined(separator: "\n")) {
                        work = candidate
                    } else {
                        resolved.warnings.append("DOI \(found) belongs to a different paper (\"\(candidate.title)\"); ignored")
                        doi = nil
                    }
                } else {
                    resolved.warnings.append("DOI \(found) is not registered with CrossRef")
                }
            } catch {
                resolved.warnings.append("CrossRef lookup failed for \(found): \(error.localizedDescription)")
                resolved.isIncomplete = true
            }
        }

        let existing = snapshot.existing
        let existingTitle = existing.title.map(HTMLText.plain).flatMap { Boilerplate.isJunkTitle($0) ? nil : $0 }
        // Registry titles carry their own blemishes (footnote markers, lost spaces around markup),
        // so a stored title that says the same thing is left as it is, unless it shows the "_"
        // of a title copied from a sanitised filename.
        let storedTitleIsAsGood = existingTitle.map {
            $0.squashedTitle == work?.fullTitle.squashedTitle && !($0.contains("_") && work?.fullTitle.contains("_") == false)
        } ?? false
        if let work, !storedTitleIsAsGood {
            (resolved.title, resolved.titleSource) = (work.fullTitle, .crossref)
        } else if let existingTitle {
            (resolved.title, resolved.titleSource) = (existingTitle, .existing)
        } else if let extracted = TitleExtractor.title(from: snapshot.firstPageRuns) {
            (resolved.title, resolved.titleSource) = (extracted, .content)
        }

        resolved.author = work.flatMap { AuthorFormatter.format($0.authors) }
            ?? existing.author.flatMap { Boilerplate.isPublisherAuthor($0) ? nil : $0 }

        // A "DOI: ..." subject is this tool's own placeholder, so better information replaces it.
        if let subject = existing.subject, !subject.hasPrefix("DOI:") {
            resolved.subject = subject
        } else {
            resolved.subject = work?.journal ?? doi.map { "DOI: \($0)" }
        }

        let kept = KeywordParser.tidy(existing.keywords.filter { !Boilerplate.isPublisherKeyword($0) })
        if kept.isEmpty || Boilerplate.keywordsLookCorrupted(kept) {
            let parsed = snapshot.pageTexts.lazy.map(KeywordParser.keywords(in:)).first { !$0.isEmpty }
            resolved.keywords = parsed ?? kept
        } else {
            resolved.keywords = kept
        }

        resolved.doi = doi
        resolved.year = work?.year
        return resolved
    }
}

public enum ChangePlan {
    /// Works out what would change for one file.
    /// - Parameter exists: whether a sibling file with the given name is already present.
    public static func make(currentFilename: String, existing: ExistingMetadata, resolved: ResolvedMetadata,
                            exists: (String) -> Bool) -> FilePlan {
        guard !resolved.isIncomplete else { return FilePlan(changes: [], newFilename: nil) }

        func change(_ field: String, _ old: String?, _ new: String?) -> FieldChange? {
            let (old, new) = (old?.nilIfEmpty, new?.nilIfEmpty)
            return old == new ? nil : FieldChange(field: field, old: old, new: new)
        }

        let changes = [
            // An unhelpful existing title still beats none, so a title is never cleared.
            resolved.title == nil ? nil : change("Title", existing.title, resolved.title),
            change("Author", existing.author, resolved.author),
            change("Subject", existing.subject, resolved.subject),
            change("Keywords", existing.keywords.joined(separator: ", "), resolved.keywords.joined(separator: ", ")),
        ].compactMap { $0 }

        return FilePlan(changes: changes, newFilename: newFilename(current: currentFilename, title: resolved.title, source: resolved.titleSource, exists: exists))
    }

    private static func newFilename(current: String, title: String?, source: MetadataSource, exists: (String) -> Bool) -> String? {
        guard let desired = FilenameBuilder.filename(forTitle: title) else { return nil }
        // A title guessed from the page is not sure enough to replace a name a person chose.
        let currentStem = (current as NSString).deletingPathExtension
        if source == .content, currentStem.contains(" "), !Boilerplate.isJunkTitle(currentStem) { return nil }
        // Stored titles are sometimes cut off; the fuller name on disk is then the better one.
        let (currentKey, desiredKey) = (currentStem.squashed, String(desired.dropLast(".pdf".count)).squashed)
        if currentKey.count > desiredKey.count, currentKey.hasPrefix(desiredKey) { return nil }
        // Names read back from disk may be in a different Unicode normal form than the title.
        let (currentName, desiredName) = (current.precomposedStringWithCanonicalMapping, desired.precomposedStringWithCanonicalMapping)
        if currentName == desiredName { return nil }
        // On a case-insensitive volume the "existing" file is this one; a case-only rename is safe.
        if currentName.lowercased() == desiredName.lowercased() || !exists(desired) { return desired }

        let stem = desired.dropLast(".pdf".count)
        return (1...1000).lazy.map { "\(stem) (\($0)).pdf" }.first { !exists($0) }
    }
}

private extension String {
    /// For comparing titles: ignores case, spacing, punctuation and a trailing footnote number.
    var squashedTitle: String {
        var text = squashed
        while text.last?.isNumber == true { text.removeLast() }
        return text
    }

    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
