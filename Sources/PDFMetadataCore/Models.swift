import Foundation

/// A stretch of page text set in a single font size.
public struct TextRun: Equatable, Sendable {
    public var text: String
    public var fontSize: Double

    public init(_ text: String, fontSize: Double) {
        self.text = text
        self.fontSize = fontSize
    }
}

/// Metadata already stored in the PDF's info dictionary.
public struct ExistingMetadata: Equatable, Sendable {
    public var title: String?
    public var author: String?
    public var subject: String?
    public var keywords: [String]

    public init(title: String? = nil, author: String? = nil, subject: String? = nil, keywords: [String] = []) {
        self.title = title
        self.author = author
        self.subject = subject
        self.keywords = keywords
    }
}

/// Everything the resolver needs from a PDF, so resolution itself never touches PDFKit.
public struct PDFSnapshot: Equatable, Sendable {
    public var existing: ExistingMetadata
    /// Plain text of the first few pages, in order.
    public var pageTexts: [String]
    public var firstPageRuns: [TextRun]

    public init(existing: ExistingMetadata = .init(), pageTexts: [String] = [], firstPageRuns: [TextRun] = []) {
        self.existing = existing
        self.pageTexts = pageTexts
        self.firstPageRuns = firstPageRuns
    }
}

public struct CrossRefWork: Equatable, Sendable, Codable {
    public var title: String
    public var subtitle: String?
    public var authors: [String]
    public var journal: String?
    public var year: Int?

    public init(title: String, subtitle: String? = nil, authors: [String] = [], journal: String? = nil, year: Int? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.authors = authors
        self.journal = journal
        self.year = year
    }
}

public protocol DOILookup: Sendable {
    /// Returns nil when the DOI is unknown to the registry.
    func lookup(doi: String) async throws -> CrossRefWork?
}

public enum MetadataSource: String, Sendable, Encodable {
    case crossref, existing, content, none
}

public struct ResolvedMetadata: Equatable, Sendable, Encodable {
    public var title: String?
    public var author: String?
    public var subject: String?
    public var keywords: [String] = []
    public var doi: String?
    public var year: Int?
    public var titleSource: MetadataSource = .none
    public var warnings: [String] = []
    /// True when a registry lookup was attempted but could not be completed; such a result should not be acted on.
    public var isIncomplete = false

    public init() {}
}

public struct FieldChange: Equatable, Sendable {
    public var field: String
    public var old: String?
    public var new: String?

    public init(field: String, old: String?, new: String?) {
        self.field = field
        self.old = old
        self.new = new
    }
}

public struct FilePlan: Equatable, Sendable {
    public var changes: [FieldChange]
    /// nil when the file already has the right name.
    public var newFilename: String?
}
