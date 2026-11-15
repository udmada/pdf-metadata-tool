import CoreGraphics
import Foundation
import Testing
@testable import PDFMetadataCore

/// A publisher-style packet: stale publisher values, an empty title, and unrelated properties to preserve.
let stalePacket = """
<?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 5.1.0">
   <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:pdf="http://ns.adobe.com/pdf/1.3/" xmlns:xmp="http://ns.adobe.com/xap/1.0/">
         <dc:format>application/pdf</dc:format>
         <dc:title><rdf:Alt><rdf:li xml:lang="x-default" /></rdf:Alt></dc:title>
         <dc:creator><rdf:Seq><rdf:li>American Medical Association</rdf:li></rdf:Seq></dc:creator>
         <dc:subject><rdf:Bag><rdf:li>The JAMA Network</rdf:li></rdf:Bag></dc:subject>
         <pdf:Keywords>The JAMA Network</pdf:Keywords>
         <pdf:Producer>PDF generator</pdf:Producer>
         <xmp:CreateDate>2022-03-21T09:13:09Z</xmp:CreateDate>
      </rdf:Description>
   </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>
"""

@Suite struct XMPPacketTests {
    @Test func readsDescriptiveFields() {
        #expect(XMPPacket.read(stalePacket) == XMPFields(
            title: nil, creators: ["American Medical Association"], description: nil,
            subjects: ["The JAMA Network"], keywords: "The JAMA Network"))
    }

    @Test func updateReplacesStaleValues() throws {
        let updated = try #require(XMPPacket.updating(stalePacket, with: metadata(title: "Sleep & Energy <Intake>")))
        #expect(XMPPacket.read(updated) == XMPFields(
            title: "Sleep & Energy <Intake>", creators: ["Esra Tasali and Eva Kahn"], description: "JAMA Internal Medicine",
            subjects: ["sleep extension", "energy intake"], keywords: "sleep extension, energy intake"))
    }

    @Test func updateRemovesFieldsThatResolvedToNothing() throws {
        let updated = try #require(XMPPacket.updating(stalePacket, with: metadata(author: nil, subject: nil, keywords: [])))
        let fields = try #require(XMPPacket.read(updated))
        #expect(fields.creators == [])
        #expect(fields.description == nil)
        #expect(fields.subjects == [])
        #expect(fields.keywords == nil)
    }

    @Test func updateKeepsStoredTitleWhenNoneWasResolved() throws {
        let titled = stalePacket.replacing(#"<rdf:li xml:lang="x-default" />"#, with: #"<rdf:li xml:lang="x-default">Stored Title</rdf:li>"#)
        let updated = try #require(XMPPacket.updating(titled, with: metadata(title: nil)))
        #expect(XMPPacket.read(updated)?.title == "Stored Title")
    }

    @Test func updateLeavesUnrelatedPropertiesAndPacketWrapperAlone() throws {
        let updated = try #require(XMPPacket.updating(stalePacket, with: metadata()))
        #expect(updated.contains("<pdf:Producer>PDF generator</pdf:Producer>"))
        #expect(updated.contains("<xmp:CreateDate>2022-03-21T09:13:09Z</xmp:CreateDate>"))
        #expect(updated.contains("<dc:format>application/pdf</dc:format>"))
        #expect(updated.hasPrefix("<?xpacket begin="))
        #expect(updated.hasSuffix(#"<?xpacket end="w"?>"#))
        #expect(!updated.contains("<?xml "))
    }

    @Test func updateReplacesPropertiesWrittenAsAttributes() throws {
        let compact = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:pdf="http://ns.adobe.com/pdf/1.3/" pdf:Keywords="stale; words" pdf:Producer="Tool"/>
        </rdf:RDF></x:xmpmeta>
        <?xpacket end="w"?>
        """
        let updated = try #require(XMPPacket.updating(compact, with: metadata()))
        #expect(XMPPacket.read(updated)?.keywords == "sleep extension, energy intake")
        #expect(XMPPacket.read(updated)?.title == "New Title: é “quoted”")
        #expect(!updated.contains("stale; words"))
        #expect(updated.contains(#"pdf:Producer="Tool""#))
    }

    @Test func refusesTextThatIsNotAnXMPPacket() {
        #expect(XMPPacket.updating("<html><body>no rdf here</body></html>", with: metadata()) == nil)
        #expect(XMPPacket.updating("not xml at all <", with: metadata()) == nil)
    }
}

/// A generated one-page PDF carrying `stalePacket` as its document-level XMP.
func makePDFWithXMP() throws -> Library {
    let library = try Library()
    try FileManager.default.removeItem(at: library.pdf)
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let info = [kCGPDFContextTitle: "Old Title", kCGPDFContextAuthor: "American Medical Association"] as CFDictionary
    let context = try #require(CGContext(library.pdf as CFURL, mediaBox: &box, info))
    context.addDocumentMetadata(Data(stalePacket.utf8) as CFData)
    context.beginPDFPage(nil)
    context.endPDFPage()
    context.closePDF()
    return library
}

@Suite struct PDFXMPTests {
    @Test func findsTheDocumentPacket() throws {
        let library = try makePDFWithXMP()
        let packet = try #require(PDFXMP.packet(in: try Data(contentsOf: library.pdf)))
        #expect(XMPPacket.read(packet)?.creators == ["American Medical Association"])
    }

    @Test func reportsNoPacketForAPDFWithoutOne() throws {
        let library = try Library()
        #expect(PDFXMP.packet(in: try Data(contentsOf: library.pdf)) == nil)
    }

    @Test func replacedPacketIsWhatReadersThenSee() throws {
        let library = try makePDFWithXMP()
        let original = try Data(contentsOf: library.pdf)
        let longer = stalePacket.replacing("American Medical Association", with: String(repeating: "A Much Longer Author Name, ", count: 40))
        let patched = try #require(PDFXMP.replacingPacket(in: original, with: longer))
        #expect(PDFXMP.packet(in: patched) == longer)
        // The original bytes are kept and only added to, as a PDF incremental update requires.
        #expect(patched.prefix(original.count) == original)
    }

    @Test func patchedFileStillOpensWithItsPagesAndInfo() throws {
        let library = try makePDFWithXMP()
        let patched = try #require(PDFXMP.replacingPacket(in: try Data(contentsOf: library.pdf), with: stalePacket.replacing("American Medical Association", with: "Someone Else")))
        try patched.write(to: library.pdf)
        #expect(try PDFReader.snapshot(of: library.pdf).existing.title == "Old Title")
        #expect(try PDFReader.snapshot(of: library.pdf).pageTexts.count == 1)
    }

    @Test func writerBringsXMPInLineWithTheInfoDictionary() throws {
        let library = try makePDFWithXMP()
        let outcome = try PDFWriter.write(metadata(), to: library.pdf)
        #expect(outcome == .updated)
        let packet = try #require(PDFXMP.packet(in: try Data(contentsOf: library.pdf)))
        #expect(XMPPacket.read(packet) == XMPFields(
            title: "New Title: é “quoted”", creators: ["Esra Tasali and Eva Kahn"], description: "JAMA Internal Medicine",
            subjects: ["sleep extension", "energy intake"], keywords: "sleep extension, energy intake"))
        #expect(try PDFReader.snapshot(of: library.pdf).existing.title == "New Title: é “quoted”")
    }

    @Test func writerReportsWhenThereIsNoXMPToUpdate() throws {
        let library = try Library()
        #expect(try PDFWriter.write(metadata(), to: library.pdf) == .absent)
        #expect(PDFXMP.packet(in: try Data(contentsOf: library.pdf)) == nil)
    }

    @Test func writingTwiceKeepsASinglePacketInSync() throws {
        let library = try makePDFWithXMP()
        try PDFWriter.write(metadata(), to: library.pdf)
        try PDFWriter.write(metadata(title: "Second Title"), to: library.pdf)
        let packet = try #require(PDFXMP.packet(in: try Data(contentsOf: library.pdf)))
        #expect(XMPPacket.read(packet)?.title == "Second Title")
    }
}
