import Foundation

/// The descriptive fields of an XMP packet that mirror the PDF info dictionary.
public struct XMPFields: Equatable, Sendable {
    public var title: String?
    public var creators: [String] = []
    public var description: String?
    public var subjects: [String] = []
    public var keywords: String?
}

public enum XMPOutcome: Equatable, Sendable {
    /// The packet now agrees with the info dictionary.
    case updated
    /// The PDF has no document-level XMP.
    case absent
    /// There is XMP, but it could not be read or safely replaced, and was left as it was.
    case unreadable
}

/// Reads and edits the XML of an XMP packet.
public enum XMPPacket {
    private struct Property {
        var prefix: String
        var name: String
        var uri: String

        func matches(_ node: XMLNode) -> Bool {
            node.localName == name && (node.uri == uri || node.prefix == prefix)
        }
    }

    private static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    private static let title = Property(prefix: "dc", name: "title", uri: "http://purl.org/dc/elements/1.1/")
    private static let creator = Property(prefix: "dc", name: "creator", uri: "http://purl.org/dc/elements/1.1/")
    private static let description = Property(prefix: "dc", name: "description", uri: "http://purl.org/dc/elements/1.1/")
    private static let subject = Property(prefix: "dc", name: "subject", uri: "http://purl.org/dc/elements/1.1/")
    private static let keywords = Property(prefix: "pdf", name: "Keywords", uri: "http://ns.adobe.com/pdf/1.3/")

    public static func read(_ packet: String) -> XMPFields? {
        guard let descriptions = descriptions(in: packet)?.1 else { return nil }
        var fields = XMPFields()
        for description in descriptions {
            for child in description.children ?? [] {
                if title.matches(child) { fields.title = values(of: child).first ?? fields.title }
                if creator.matches(child) { fields.creators += values(of: child) }
                if Self.description.matches(child) { fields.description = values(of: child).first ?? fields.description }
                if subject.matches(child) { fields.subjects += values(of: child) }
                if keywords.matches(child) { fields.keywords = values(of: child).first ?? fields.keywords }
            }
            // Simple properties may be written as attributes of the description instead of child elements.
            if let attribute = description.attributes?.first(where: keywords.matches), let value = attribute.stringValue, !value.isEmpty {
                fields.keywords = value
            }
        }
        return fields
    }

    /// The packet with its title, creator, description, subject and keywords set from `metadata`,
    /// following the same rules as the info dictionary: a nil title is left alone, other empty fields are removed.
    /// Returns nil if the text is not an XMP packet.
    public static func updating(_ packet: String, with metadata: ResolvedMetadata) -> String? {
        guard let (document, descriptions) = descriptions(in: packet) else { return nil }
        let managed = (metadata.title == nil ? [] : [title]) + [creator, description, subject, keywords]

        for description in descriptions {
            for (index, child) in (description.children ?? []).enumerated().reversed() where managed.contains(where: { $0.matches(child) }) {
                description.removeChild(at: index)
            }
            for attribute in description.attributes ?? [] where managed.contains(where: { $0.matches(attribute) }) {
                if let name = attribute.name { description.removeAttribute(forName: name) }
            }
        }

        let target = descriptions[0]
        func add(_ property: Property, _ kind: String?, _ items: [String]) {
            guard !items.isEmpty else { return }
            if target.resolveNamespace(forName: "\(property.prefix):\(property.name)") == nil,
               let namespace = XMLNode.namespace(withName: property.prefix, stringValue: property.uri) as? XMLNode {
                target.addNamespace(namespace)
            }
            let element = XMLElement(name: "\(property.prefix):\(property.name)")
            if let kind {
                let list = XMLElement(name: "rdf:\(kind)")
                for item in items {
                    let entry = XMLElement(name: "rdf:li", stringValue: item)
                    // Language alternatives need a default language; plain lists do not.
                    if kind == "Alt", let language = XMLNode.attribute(withName: "xml:lang", stringValue: "x-default") as? XMLNode {
                        entry.addAttribute(language)
                    }
                    list.addChild(entry)
                }
                element.addChild(list)
            } else {
                element.stringValue = items[0]
            }
            target.addChild(element)
        }
        add(title, "Alt", [metadata.title].compactMap { $0 })
        add(creator, "Seq", [metadata.author].compactMap { $0 })
        add(description, "Alt", [metadata.subject].compactMap { $0 })
        add(subject, "Bag", metadata.keywords)
        add(keywords, nil, metadata.keywords.isEmpty ? [] : [metadata.keywords.joined(separator: ", ")])

        return document.xmlString(options: [.nodePreserveAll])
            .replacing(#/^\s*<\?xml [^>]*\?>/#, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func descriptions(in packet: String) -> (XMLDocument, [XMLElement])? {
        guard let document = try? XMLDocument(xmlString: packet, options: [.nodePreserveAll]),
              let root = document.rootElement() else { return nil }
        var found: [XMLElement] = []
        func visit(_ element: XMLElement) {
            if element.localName == "Description", element.uri == rdf || element.prefix == "rdf" { found.append(element) }
            for case let child as XMLElement in element.children ?? [] { visit(child) }
        }
        visit(root)
        return found.isEmpty ? nil : (document, found)
    }

    /// The values of a property: its list entries, or its own text for a simple property.
    private static func values(of property: XMLNode) -> [String] {
        var entries: [XMLNode] = []
        func collect(_ node: XMLNode) {
            for child in node.children ?? [] {
                if child.localName == "li" { entries.append(child) } else { collect(child) }
            }
        }
        collect(property)
        return (entries.isEmpty ? [property] : entries)
            .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// Finds and replaces the document-level XMP stream in the bytes of a PDF.
///
/// Understands classic cross-reference tables only, which is what PDFKit writes; anything else
/// is reported as unreadable rather than guessed at.
public enum PDFXMP {
    enum Location {
        case absent
        case unreadable
        case found(object: Int, packet: String)
    }

    public static func packet(in pdf: Data) -> String? {
        if case .found(_, let packet) = locate(in: pdf) { return packet }
        return nil
    }

    /// The PDF with `packet` as its XMP, added as an incremental update: the existing bytes are
    /// kept and a new version of the metadata object is appended, with a cross-reference section
    /// that points to it. Returns nil if the PDF has no readable XMP to replace.
    public static func replacingPacket(in pdf: Data, with packet: String) -> Data? {
        guard case .found(let object, _) = locate(in: pdf),
              let startxref = lastStartxref(in: pdf), let section = section(in: pdf, at: startxref) else { return nil }
        // The new trailer repeats the old one and points back to the cross-reference table it extends.
        var trailer = section.trailer.replacing(#/\/Prev\s+\d+/#, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dictionaryEnd = trailer.range(of: ">>", options: .backwards) else { return nil }
        trailer.insert(contentsOf: "/Prev \(startxref) ", at: dictionaryEnd.lowerBound)

        let content = Data(packet.utf8)
        var output = pdf
        if output.last != UInt8(ascii: "\n") { output.append(UInt8(ascii: "\n")) }

        let objectOffset = output.count
        output.append(Data("\(object) 0 obj\n<< /Type /Metadata /Subtype /XML /Length \(content.count) >>\nstream\n".utf8))
        output.append(content)
        output.append(Data("\nendstream\nendobj\n".utf8))

        let xrefOffset = output.count
        // Each cross-reference entry is exactly 20 bytes: 10-digit offset, 5-digit generation, "n", space, newline.
        let entry = String(repeating: "0", count: 10 - String(objectOffset).count) + "\(objectOffset) 00000 n \n"
        output.append(Data("xref\n\(object) 1\n\(entry)trailer\n\(trailer)\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
        return output
    }

    static func locate(in pdf: Data) -> Location {
        guard let startxref = lastStartxref(in: pdf), let newest = section(in: pdf, at: startxref),
              let root = newest.trailer.firstMatch(of: #/\/Root\s+(\d+)\s+0\s+R/#).flatMap({ Int($0.1) }),
              let catalog = objectText(root, in: pdf, from: startxref, upTo: "endobj") else { return .unreadable }
        guard let object = catalog.firstMatch(of: #/\/Metadata\s+(\d+)\s+0\s+R/#).flatMap({ Int($0.1) }) else { return .absent }

        guard let offset = offset(of: object, in: pdf, from: startxref),
              let keyword = pdf.range(of: Data("stream".utf8), in: offset..<pdf.count),
              keyword.lowerBound - offset < 4096 else { return .unreadable }
        let header = String(decoding: pdf[offset..<keyword.lowerBound], as: UTF8.self)

        var start = keyword.upperBound
        if start < pdf.count, pdf[start] == UInt8(ascii: "\r") { start += 1 }
        if start < pdf.count, pdf[start] == UInt8(ascii: "\n") { start += 1 }
        var content: Data
        // A length given directly is exact; one given by reference is found by the closing keyword instead.
        if let declared = header.firstMatch(of: #/\/Length\s+(\d+)(\s+\d+\s+R)?/#), declared.2 == nil,
           let length = Int(declared.1), start + length <= pdf.count {
            content = Data(pdf[start..<(start + length)])
        } else {
            guard let end = pdf.range(of: Data("endstream".utf8), in: start..<pdf.count)?.lowerBound else { return .unreadable }
            content = Data(pdf[start..<end])
            if content.last == UInt8(ascii: "\n") { content.removeLast() }
            if content.last == UInt8(ascii: "\r") { content.removeLast() }
        }

        if header.contains("/Filter") {
            // Deflate is the only compression handled. Its stream opens with a two-byte zlib header
            // that Foundation's raw-deflate decoder does not expect.
            let filters = header.matches(of: #/\/(\w+Decode)\b/#).map { String($0.1) }
            guard filters == ["FlateDecode"], !header.contains("/DecodeParms"), content.count > 2,
                  let inflated = try? (content.dropFirst(2) as NSData).decompressed(using: .zlib) else { return .unreadable }
            content = inflated as Data
        }

        guard let packet = String(data: content, encoding: .utf8), packet.contains("<?xpacket") || packet.contains("xmpmeta") else { return .unreadable }
        return .found(object: object, packet: packet)
    }

    private struct Section {
        var offsets: [Int: Int]
        var trailer: String
        var previous: Int?
    }

    private static func lastStartxref(in pdf: Data) -> Int? {
        guard let keyword = pdf.range(of: Data("startxref".utf8), options: .backwards) else { return nil }
        let tail = String(decoding: pdf[keyword.upperBound...].prefix(32), as: UTF8.self)
        return tail.firstMatch(of: #/\d+/#).flatMap { Int($0.0) }
    }

    /// One cross-reference table and its trailer dictionary.
    private static func section(in pdf: Data, at position: Int) -> Section? {
        guard position >= 0, position + 4 <= pdf.count, pdf[position..<position + 4] == Data("xref".utf8),
              let trailerKeyword = pdf.range(of: Data("trailer".utf8), in: position..<pdf.count),
              let end = pdf.range(of: Data("startxref".utf8), in: trailerKeyword.upperBound..<pdf.count) else { return nil }

        let tokens = String(decoding: pdf[(position + 4)..<trailerKeyword.lowerBound], as: UTF8.self).split(whereSeparator: \.isWhitespace)
        var offsets: [Int: Int] = [:]
        var index = 0
        // Subsections: a "first count" header, then one "offset generation n|f" entry per object.
        while index + 1 < tokens.count, let first = Int(tokens[index]), let count = Int(tokens[index + 1]), first >= 0, count >= 0 {
            index += 2
            var number = first
            while number < first + count, index + 2 < tokens.count {
                if tokens[index + 2] == "n", let offset = Int(tokens[index]) { offsets[number] = offset }
                index += 3
                number += 1
            }
        }

        let trailer = String(decoding: pdf[trailerKeyword.upperBound..<end.lowerBound], as: UTF8.self)
        let previous = trailer.firstMatch(of: #/\/Prev\s+(\d+)/#).flatMap { Int($0.1) }
        return Section(offsets: offsets, trailer: trailer, previous: previous)
    }

    /// Where an object lives, looking through cross-reference sections newest first.
    private static func offset(of object: Int, in pdf: Data, from startxref: Int) -> Int? {
        var position: Int? = startxref
        for _ in 0..<64 {
            guard let current = position, let section = section(in: pdf, at: current) else { return nil }
            if let offset = section.offsets[object], offset < pdf.count { return offset }
            position = section.previous
        }
        return nil
    }

    private static func objectText(_ object: Int, in pdf: Data, from startxref: Int, upTo terminator: String) -> String? {
        guard let offset = offset(of: object, in: pdf, from: startxref),
              let end = pdf.range(of: Data(terminator.utf8), in: offset..<pdf.count) else { return nil }
        return String(decoding: pdf[offset..<end.lowerBound], as: UTF8.self)
    }
}
