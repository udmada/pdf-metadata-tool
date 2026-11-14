import Foundation
import PDFKit

public enum PDFReader {
    public enum ReadError: Error, LocalizedError {
        case unreadable
        case locked

        public var errorDescription: String? {
            switch self {
            case .unreadable: "not a readable PDF"
            case .locked: "PDF is password protected"
            }
        }
    }

    public static func snapshot(of url: URL, pageLimit: Int = 3) throws -> PDFSnapshot {
        guard let document = PDFDocument(url: url) else { throw ReadError.unreadable }
        guard !document.isLocked else { throw ReadError.locked }

        let attributes = document.documentAttributes ?? [:]
        func text(_ key: PDFDocumentAttribute) -> String? {
            guard let value = (attributes[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            return value.isEmpty ? nil : value
        }
        // PDFKit hands back keywords pre-split on commas only; finish the job for other separators.
        let rawKeywords = attributes[PDFDocumentAttribute.keywordsAttribute]
        let keywords = (rawKeywords as? [String] ?? (rawKeywords as? String).map { [$0] } ?? [])

        let pages = (0..<min(pageLimit, document.pageCount)).compactMap(document.page(at:))
        return PDFSnapshot(
            existing: ExistingMetadata(
                title: text(.titleAttribute),
                author: text(.authorAttribute),
                subject: text(.subjectAttribute),
                keywords: keywords.flatMap(KeywordParser.split)
            ),
            pageTexts: pages.map { $0.string ?? "" },
            firstPageRuns: pages.first.map(runs(on:)) ?? []
        )
    }

    private static func runs(on page: PDFPage) -> [TextRun] {
        guard let attributed = quietly({ page.attributedString }) else { return [] }
        var runs: [TextRun] = []
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            let text = attributed.attributedSubstring(from: range).string
            // Whitespace between words is often set in a stray font; keep it with the preceding run
            // so it neither becomes a run of its own nor gets lost.
            if text.allSatisfy(\.isWhitespace), !runs.isEmpty {
                runs[runs.count - 1].text += text
            } else if let font = value as? NSFont {
                runs.append(TextRun(text, fontSize: font.pointSize))
            }
        }
        return runs
    }
}

private let stderrLock = NSLock()

/// Runs `body` with stderr discarded: PDFKit logs debug chatter there for every page it lays out.
private func quietly<T>(_ body: () -> T) -> T {
    stderrLock.withLock {
        fflush(stderr)
        let saved = dup(STDERR_FILENO)
        let null = open("/dev/null", O_WRONLY)
        dup2(null, STDERR_FILENO)
        close(null)
        defer {
            fflush(stderr)
            dup2(saved, STDERR_FILENO)
            close(saved)
        }
        return body()
    }
}

public enum PDFFinder {
    /// PDFs at `url`: the file itself, or the PDFs in a directory. Skips hidden files and `backups` folders.
    public static func find(at url: URL, recursive: Bool) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { return isPDF(url) ? [url] : [] }

        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: options) else { return [] }

        var found: [URL] = []
        for case let item as URL in enumerator {
            if item.lastPathComponent == "backups" {
                enumerator.skipDescendants()
            } else if isPDF(item) {
                found.append(item)
            }
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func isPDF(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf"
    }
}
