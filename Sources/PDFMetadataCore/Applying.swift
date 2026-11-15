import Foundation
import PDFKit

public struct AppliedChange: Equatable, Sendable {
    public var finalURL: URL
    public var wroteMetadata: Bool
    public var backupURL: URL?
    /// What happened to the embedded XMP block, when the file was rewritten.
    public var xmp: XMPOutcome?
}

public enum PDFWriter {
    public enum WriteError: Error, LocalizedError {
        case unreadable
        case encrypted
        case writeFailed
        case verificationFailed

        public var errorDescription: String? {
            switch self {
            case .unreadable: "not a readable PDF"
            case .encrypted: "PDF is encrypted; left unchanged"
            case .writeFailed: "PDFKit could not write the file; left unchanged"
            case .verificationFailed: "rewritten copy did not match the original; left unchanged"
            }
        }
    }

    /// Stores title, author, subject and keywords in the PDF's info dictionary.
    /// A nil author or subject, or empty keywords, clears that field; a nil title leaves the stored one.
    ///
    /// The file is rewritten to a staging location and checked before it replaces the original,
    /// so a failure at any point leaves the original as it was.
    @discardableResult
    public static func write(_ metadata: ResolvedMetadata, to url: URL) throws -> XMPOutcome {
        guard let document = PDFDocument(url: url) else { throw WriteError.unreadable }
        // PDFKit would silently drop the encryption on save.
        guard !document.isEncrypted else { throw WriteError.encrypted }

        var attributes = document.documentAttributes ?? [:]
        func store(_ value: Any?, as key: PDFDocumentAttribute) {
            if let value {
                attributes[key] = value
            } else {
                attributes.removeValue(forKey: key)
            }
        }
        if let title = metadata.title { store(title, as: .titleAttribute) }
        store(metadata.author, as: .authorAttribute)
        store(metadata.subject, as: .subjectAttribute)
        store(metadata.keywords.isEmpty ? nil : metadata.keywords, as: .keywordsAttribute)
        store(Date(), as: .modificationDateAttribute)
        document.documentAttributes = attributes

        let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(url.lastPathComponent)
        guard document.write(to: staged) else { throw WriteError.writeFailed }

        func stagedCopyIsSound() -> Bool {
            guard let written = PDFDocument(url: staged) else { return false }
            return written.pageCount == document.pageCount && matches(written.documentAttributes ?? [:], attributes)
        }
        guard stagedCopyIsSound() else { throw WriteError.verificationFailed }

        // PDFKit carries an embedded XMP block over untouched, so it is brought into line separately.
        let rewritten = try Data(contentsOf: staged)
        var outcome = XMPOutcome.absent
        switch PDFXMP.locate(in: rewritten) {
        case .absent:
            break
        case .unreadable:
            outcome = .unreadable
        case .found(_, let packet):
            outcome = .unreadable
            if let updated = XMPPacket.updating(packet, with: metadata),
               let patched = PDFXMP.replacingPacket(in: rewritten, with: updated) {
                try patched.write(to: staged)
                if stagedCopyIsSound() {
                    outcome = .updated
                } else {
                    // Fall back to the copy already known to be good.
                    try rewritten.write(to: staged)
                }
            }
        }

        _ = try FileManager.default.replaceItemAt(url, withItemAt: staged)
        return outcome
    }

    private static func matches(_ written: [AnyHashable: Any], _ intended: [AnyHashable: Any]) -> Bool {
        func text(_ attributes: [AnyHashable: Any], _ key: PDFDocumentAttribute) -> String {
            (attributes[key] as? String) ?? (attributes[key] as? [String])?.joined(separator: ", ") ?? ""
        }
        return [PDFDocumentAttribute.titleAttribute, .authorAttribute, .subjectAttribute, .keywordsAttribute]
            .allSatisfy { text(written, $0) == text(intended, $0) }
    }
}

public enum FileOperations {
    public enum RenameError: Error, LocalizedError {
        case destinationExists(String)

        public var errorDescription: String? {
            switch self {
            case .destinationExists(let name): "a file named \"\(name)\" already exists; not renamed"
            }
        }
    }

    /// Copies the file into a `backups` folder beside it, never overwriting an earlier backup.
    public static func backup(_ url: URL) throws -> URL {
        let folder = url.deletingLastPathComponent().appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = url.deletingPathExtension().lastPathComponent
        var destination = folder.appendingPathComponent("\(stem).backup.pdf")
        var counter = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(stem).backup\(counter).pdf")
            counter += 1
        }
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    /// Renames the file within its folder, refusing to replace a different file.
    public static func rename(_ url: URL, to name: String) throws -> URL {
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        // On a case-insensitive volume a case-only rename "exists" already, as the file itself.
        let isSameFile = url.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
            == name.precomposedStringWithCanonicalMapping.lowercased()
        guard isSameFile || !FileManager.default.fileExists(atPath: destination.path) else {
            throw RenameError.destinationExists(name)
        }
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}

public enum ChangeApplier {
    /// Carries out a plan: backs up and rewrites the file if any field changes, then renames it.
    /// - Parameter metadata: the resolution the plan was made from.
    public static func apply(_ plan: FilePlan, metadata: ResolvedMetadata, to url: URL, backup: Bool) throws -> AppliedChange {
        var applied = AppliedChange(finalURL: url, wroteMetadata: false, backupURL: nil)
        if !plan.changes.isEmpty {
            // Only a rewrite puts the file's contents at risk; a rename alone needs no copy.
            if backup { applied.backupURL = try FileOperations.backup(url) }
            applied.xmp = try PDFWriter.write(metadata, to: url)
            applied.wroteMetadata = true
        }
        if let name = plan.newFilename {
            applied.finalURL = try FileOperations.rename(url, to: name)
        }
        return applied
    }
}
