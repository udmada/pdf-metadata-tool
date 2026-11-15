import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import PDFMetadataCore

/// A scratch folder holding one generated PDF with stored metadata, removed when the test ends.
final class Library {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pdfmeta-lib-\(UUID().uuidString)")
    let pdf: URL

    init(named name: String = "download.pdf") throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let made = try makePDF(title: "A Study of Sleep and Energy Intake", body: "Body text of the paper goes here.", info: [
            kCGPDFContextTitle: "Old Title", kCGPDFContextAuthor: "American Medical Association",
            kCGPDFContextSubject: "Old Subject", kCGPDFContextKeywords: "The JAMA Network",
        ])
        pdf = folder.appendingPathComponent(name)
        try FileManager.default.moveItem(at: made, to: pdf)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    func names(in subfolder: String = "") -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(subfolder).path)) ?? []).sorted()
    }
}

func metadata(title: String? = "New Title: é “quoted”", author: String? = "Esra Tasali and Eva Kahn",
              subject: String? = "JAMA Internal Medicine", keywords: [String] = ["sleep extension", "energy intake"]) -> ResolvedMetadata {
    var resolved = ResolvedMetadata()
    (resolved.title, resolved.author, resolved.subject, resolved.keywords) = (title, author, subject, keywords)
    return resolved
}

@Suite struct PDFWriterTests {
    @Test func writesAllFourFields() throws {
        let library = try Library()
        try PDFWriter.write(metadata(), to: library.pdf)
        #expect(try PDFReader.snapshot(of: library.pdf).existing == ExistingMetadata(
            title: "New Title: é “quoted”", author: "Esra Tasali and Eva Kahn",
            subject: "JAMA Internal Medicine", keywords: ["sleep extension", "energy intake"]))
    }

    @Test func clearsFieldsThatResolvedToNothing() throws {
        let library = try Library()
        try PDFWriter.write(metadata(author: nil, subject: nil, keywords: []), to: library.pdf)
        let stored = try PDFReader.snapshot(of: library.pdf).existing
        #expect(stored.author == nil)
        #expect(stored.subject == nil)
        #expect(stored.keywords == [])
    }

    @Test func keepsStoredTitleWhenNoneWasResolved() throws {
        let library = try Library()
        try PDFWriter.write(metadata(title: nil), to: library.pdf)
        #expect(try PDFReader.snapshot(of: library.pdf).existing.title == "Old Title")
    }

    @Test func leavesPageContentUnchanged() throws {
        let library = try Library()
        let before = try PDFReader.snapshot(of: library.pdf)
        try PDFWriter.write(metadata(), to: library.pdf)
        let after = try PDFReader.snapshot(of: library.pdf)
        #expect(after.pageTexts == before.pageTexts)
        #expect(after.firstPageRuns == before.firstPageRuns)
    }

    @Test func stampsModificationDate() throws {
        let library = try Library()
        let start = Date().addingTimeInterval(-2)
        try PDFWriter.write(metadata(), to: library.pdf)
        let stamped = PDFDocument(url: library.pdf)?.documentAttributes?[PDFDocumentAttribute.modificationDateAttribute] as? Date
        #expect(try #require(stamped) > start)
    }

    @Test func leavesNoStrayFilesBesideThePDF() throws {
        let library = try Library()
        try PDFWriter.write(metadata(), to: library.pdf)
        #expect(library.names() == ["download.pdf"])
    }

    @Test func refusesAFileThatIsNotAPDFAndLeavesItIntact() throws {
        let library = try Library()
        let bogus = library.folder.appendingPathComponent("bogus.pdf")
        try Data("not a pdf".utf8).write(to: bogus)
        #expect(throws: (any Error).self) { try PDFWriter.write(metadata(), to: bogus) }
        #expect(try Data(contentsOf: bogus) == Data("not a pdf".utf8))
    }
}

@Suite struct FileOperationsTests {
    @Test func backupIsAnIdenticalCopyInABackupsFolder() throws {
        let library = try Library()
        let backup = try FileOperations.backup(library.pdf)
        #expect(backup.deletingLastPathComponent().lastPathComponent == "backups")
        #expect(backup.lastPathComponent == "download.backup.pdf")
        #expect(try Data(contentsOf: backup) == Data(contentsOf: library.pdf))
    }

    @Test func laterBackupsDoNotOverwriteEarlierOnes() throws {
        let library = try Library()
        _ = try FileOperations.backup(library.pdf)
        _ = try FileOperations.backup(library.pdf)
        #expect(library.names(in: "backups") == ["download.backup.pdf", "download.backup1.pdf"])
    }

    @Test func renameMovesTheFile() throws {
        let library = try Library()
        let moved = try FileOperations.rename(library.pdf, to: "Sleep - A Trial.pdf")
        #expect(moved.lastPathComponent == "Sleep - A Trial.pdf")
        #expect(library.names() == ["Sleep - A Trial.pdf"])
    }

    @Test func renameNeverOverwritesAnotherFile() throws {
        let library = try Library()
        let other = library.folder.appendingPathComponent("Taken.pdf")
        try Data("other".utf8).write(to: other)
        #expect(throws: (any Error).self) { try FileOperations.rename(library.pdf, to: "Taken.pdf") }
        #expect(try Data(contentsOf: other) == Data("other".utf8))
        #expect(library.names() == ["Taken.pdf", "download.pdf"])
    }
}

@Suite struct ChangeApplierTests {
    let titleChange = [FieldChange(field: "Title", old: "Old Title", new: "New Title")]

    @Test func writesMetadataThenRenamesKeepingABackupOfTheOriginal() throws {
        let library = try Library()
        let plan = FilePlan(changes: titleChange, newFilename: "New Title.pdf")
        let applied = try ChangeApplier.apply(plan, metadata: metadata(title: "New Title"), to: library.pdf, backup: true)

        #expect(applied.wroteMetadata)
        #expect(applied.finalURL.lastPathComponent == "New Title.pdf")
        #expect(library.names() == ["New Title.pdf", "backups"])
        #expect(try PDFReader.snapshot(of: applied.finalURL).existing.title == "New Title")
        #expect(try PDFReader.snapshot(of: try #require(applied.backupURL)).existing.title == "Old Title")
    }

    @Test func renameAloneNeedsNoBackupAndLeavesBytesAlone() throws {
        let library = try Library()
        let original = try Data(contentsOf: library.pdf)
        let applied = try ChangeApplier.apply(FilePlan(changes: [], newFilename: "Renamed.pdf"), metadata: metadata(), to: library.pdf, backup: true)
        #expect(!applied.wroteMetadata)
        #expect(applied.backupURL == nil)
        #expect(library.names() == ["Renamed.pdf"])
        #expect(try Data(contentsOf: applied.finalURL) == original)
    }

    @Test func emptyPlanTouchesNothing() throws {
        let library = try Library()
        let original = try Data(contentsOf: library.pdf)
        let applied = try ChangeApplier.apply(FilePlan(changes: [], newFilename: nil), metadata: metadata(), to: library.pdf, backup: true)
        #expect(applied == AppliedChange(finalURL: library.pdf, wroteMetadata: false, backupURL: nil))
        #expect(try Data(contentsOf: library.pdf) == original)
    }

    @Test func backupCanBeTurnedOff() throws {
        let library = try Library()
        let applied = try ChangeApplier.apply(FilePlan(changes: titleChange, newFilename: nil), metadata: metadata(title: "New Title"), to: library.pdf, backup: false)
        #expect(applied.wroteMetadata)
        #expect(applied.backupURL == nil)
        #expect(library.names() == ["download.pdf"])
    }
}
