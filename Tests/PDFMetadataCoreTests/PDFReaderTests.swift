import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import PDFMetadataCore

/// Writes a one-page PDF with a large title line and a small body line.
func makePDF(title: String, body: String, info: [CFString: Any]) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdfmeta-\(UUID().uuidString).pdf")
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(url as CFURL, mediaBox: &box, info as CFDictionary))
    context.beginPDFPage(nil)
    for (text, size, y) in [(title, 18.0, 700.0), (body, 10.0, 660.0)] {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        context.textPosition = CGPoint(x: 72, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
    }
    context.endPDFPage()
    context.closePDF()
    return url
}

@Suite struct PDFReaderTests {
    @Test func readsInfoDictionaryAndSplitsKeywords() throws {
        let url = try makePDF(title: "A Study of Sleep and Energy Intake", body: "Body text of the paper goes here.", info: [
            kCGPDFContextTitle: "Stored Title", kCGPDFContextAuthor: "Stored Author",
            kCGPDFContextSubject: "Stored Subject", kCGPDFContextKeywords: "sleep; energy intake",
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = try PDFReader.snapshot(of: url)
        #expect(snapshot.existing == ExistingMetadata(title: "Stored Title", author: "Stored Author", subject: "Stored Subject", keywords: ["sleep", "energy intake"]))
    }

    @Test func treatsBlankInfoFieldsAsMissing() throws {
        let url = try makePDF(title: "A Study of Sleep and Energy Intake", body: "Body text.", info: [kCGPDFContextTitle: "  "])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try PDFReader.snapshot(of: url).existing == ExistingMetadata())
    }

    @Test func readsPageTextAndFontSizes() throws {
        let url = try makePDF(title: "A Study of Sleep and Energy Intake", body: "Body text of the paper goes here.", info: [:])
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = try PDFReader.snapshot(of: url)
        #expect(snapshot.pageTexts.first?.contains("A Study of Sleep and Energy Intake") == true)
        #expect(TitleExtractor.title(from: snapshot.firstPageRuns) == "A Study of Sleep and Energy Intake")
    }

    @Test func throwsForAFileThatIsNotAPDF() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdfmeta-\(UUID().uuidString).pdf")
        try Data("not a pdf".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: (any Error).self) { try PDFReader.snapshot(of: url) }
    }
}

@Suite struct PDFFinderTests {
    /// Builds a folder holding PDFs at the top level, in a subfolder, in `backups`, plus non-PDF and hidden files.
    func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pdfmeta-tree-\(UUID().uuidString)")
        for path in ["b.pdf", "A.PDF", "notes.md", ".hidden.pdf", "sub/c.pdf", "backups/d.backup.pdf"] {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        return root
    }

    @Test func listsOnlyTopLevelPDFsByDefault() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(PDFFinder.find(at: root, recursive: false).map(\.lastPathComponent) == ["A.PDF", "b.pdf"])
    }

    @Test func recursiveSearchDescendsButSkipsBackups() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(PDFFinder.find(at: root, recursive: true).map(\.lastPathComponent) == ["A.PDF", "b.pdf", "c.pdf"])
    }

    @Test func acceptsASinglePDFButNotOtherFiles() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(PDFFinder.find(at: root.appendingPathComponent("b.pdf"), recursive: false).count == 1)
        #expect(PDFFinder.find(at: root.appendingPathComponent("notes.md"), recursive: false).isEmpty)
    }
}
