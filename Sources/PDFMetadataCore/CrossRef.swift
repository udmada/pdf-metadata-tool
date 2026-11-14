import Foundation

extension CrossRefWork {
    private struct Envelope: Decodable {
        let message: Message
    }

    private struct Message: Decodable {
        let type: String?
        let title: [String]?
        let subtitle: [String]?
        let author: [Author]?
        let containerTitle: [String]?
        let publishedPrint: PartialDate?
        let publishedOnline: PartialDate?
        let issued: PartialDate?

        enum CodingKeys: String, CodingKey {
            case type, title, subtitle, author, issued
            case containerTitle = "container-title"
            case publishedPrint = "published-print"
            case publishedOnline = "published-online"
        }
    }

    private struct Author: Decodable {
        let given: String?
        let family: String?
        let name: String?
    }

    private struct PartialDate: Decodable {
        let dateParts: [[Int?]]?

        enum CodingKeys: String, CodingKey {
            case dateParts = "date-parts"
        }

        var year: Int? { dateParts?.first?.first ?? nil }
    }

    /// Record types that describe a container rather than a single work.
    private static let containerTypes: Set = ["journal", "journal-volume", "journal-issue", "book-series", "proceedings-series"]

    /// Decodes a CrossRef `/works/{doi}` response. Returns nil for a record that is not a titled work.
    public static func decode(from data: Data) throws -> CrossRefWork? {
        let message = try JSONDecoder().decode(Envelope.self, from: data).message
        if let type = message.type, containerTypes.contains(type) { return nil }
        guard let title = message.title?.first.map(HTMLText.plain), !title.isEmpty else { return nil }

        let authors = (message.author ?? []).compactMap { author -> String? in
            let person = [author.given, author.family].compactMap { $0 }.joined(separator: " ")
            let name = author.family == nil ? (author.name ?? person) : person
            if name.isEmpty { return nil }
            // Some publishers register names in capitals.
            let isShouting = name.count > 4 && name == name.uppercased() && name != name.lowercased()
            return (isShouting ? name.capitalized : name).collapsingWhitespace
        }
        let subtitle = message.subtitle?.first.map(HTMLText.plain)
        let journal = message.containerTitle?.first.map(HTMLText.plain)
        return CrossRefWork(
            title: title,
            subtitle: subtitle?.isEmpty == false ? subtitle : nil,
            authors: authors,
            journal: journal?.isEmpty == false ? journal : nil,
            year: message.publishedPrint?.year ?? message.publishedOnline?.year ?? message.issued?.year
        )
    }

    /// Title with its subtitle, unless the registry already folded the subtitle into the title.
    public var fullTitle: String {
        guard let subtitle, !title.squashed.contains(subtitle.squashed) else { return title }
        return "\(title): \(subtitle)"
    }
}

public struct CrossRefClient: DOILookup {
    public enum LookupError: Error, LocalizedError {
        case http(Int)

        public var errorDescription: String? {
            switch self {
            case .http(let status): "CrossRef returned HTTP \(status)"
            }
        }
    }

    private let userAgent: String

    /// - Parameter mailto: contact address for CrossRef's "polite pool"; omitted from requests when nil.
    public init(mailto: String? = nil) {
        userAgent = "pdfmeta/0.1" + (mailto.map { " (mailto:\($0))" } ?? "")
    }

    public func lookup(doi: String) async throws -> CrossRefWork? {
        guard let path = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.crossref.org/works/\(path)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        var (data, response) = try await fetch(request)
        var status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // Back off and retry when rate limited, honouring the server's Retry-After when it gives one.
        for attempt in 1...3 where status == 429 {
            let wait = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? Double(attempt * 2)
            try await Task.sleep(for: .seconds(min(wait, 30)))
            (data, response) = try await fetch(request)
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        }
        if status == 404 { return nil }
        guard status == 200 else { throw LookupError.http(status) }
        return try CrossRefWork.decode(from: data)
    }
}

extension CrossRefClient {
    /// CrossRef's public pool occasionally stalls; one retry gets past most of those.
    private func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch URLError.timedOut {
            return try await URLSession.shared.data(for: request)
        }
    }
}

/// Remembers registry answers on disk, so a preview and the run that follows it see the same data.
public struct CachingLookup: DOILookup {
    private struct Entry: Codable {
        var work: CrossRefWork?
    }

    private let base: any DOILookup
    private let directory: URL

    public init(_ base: any DOILookup, directory: URL) {
        self.base = base
        self.directory = directory
    }

    public func lookup(doi: String) async throws -> CrossRefWork? {
        // DOIs are case-insensitive and full of path characters; escape everything but letters and digits.
        let name = doi.lowercased().addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? doi
        let file = directory.appendingPathComponent(name + ".json")
        if let data = try? Data(contentsOf: file), let entry = try? JSONDecoder().decode(Entry.self, from: data) {
            return entry.work
        }

        let work = try await base.lookup(doi: doi)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(Entry(work: work)).write(to: file, options: .atomic)
        return work
    }
}
