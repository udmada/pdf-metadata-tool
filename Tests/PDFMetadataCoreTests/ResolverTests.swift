import Foundation
import Testing
@testable import PDFMetadataCore

struct FakeLookup: DOILookup {
    struct Failure: Error {}
    var work: CrossRefWork?
    var fails = false

    func lookup(doi: String) async throws -> CrossRefWork? {
        if fails { throw Failure() }
        return work
    }
}

let jamaTitle = "Effect of Sleep Extension on Objectively Assessed Energy Intake Among Adults With Overweight in Real-life Settings"

let jamaSnapshot = PDFSnapshot(
    existing: ExistingMetadata(title: nil, author: "American Medical Association", subject: nil, keywords: ["The JAMA Network"]),
    pageTexts: ["Research\n\(jamaTitle)\nA Randomized Clinical Trial\nEsra Tasali, MD\nJAMA Intern Med. doi:10.1001/jamainternmed.2021.8098"],
    firstPageRuns: [TextRun("Research", fontSize: 9), TextRun(jamaTitle, fontSize: 15), TextRun("Esra Tasali, MD", fontSize: 7.5)]
)

let jamaWork = CrossRefWork(
    title: jamaTitle,
    authors: ["Esra Tasali", "Kristen Wroblewski", "Eva Kahn"],
    journal: "JAMA Internal Medicine",
    year: 2022
)

@Suite struct MetadataResolverTests {
    @Test func verifiedCrossRefRecordReplacesPublisherBoilerplate() async {
        let resolved = await MetadataResolver(lookup: FakeLookup(work: jamaWork)).resolve(jamaSnapshot)
        #expect(resolved.title == jamaTitle)
        #expect(resolved.titleSource == .crossref)
        #expect(resolved.author == "Esra Tasali, Kristen Wroblewski, and Eva Kahn")
        #expect(resolved.subject == "JAMA Internal Medicine")
        #expect(resolved.keywords == [])
        #expect(resolved.doi == "10.1001/jamainternmed.2021.8098")
        #expect(resolved.year == 2022)
        #expect(resolved.warnings == [])
    }

    @Test func crossRefRecordForADifferentPaperIsIgnored() async {
        var snapshot = jamaSnapshot
        snapshot.existing.title = "My Own Correct Title For This Paper"
        let wrong = CrossRefWork(title: "Methamphetamine use among people who inject drugs in Iran", authors: ["Someone Else"], journal: "Other Journal")
        let resolved = await MetadataResolver(lookup: FakeLookup(work: wrong)).resolve(snapshot)
        #expect(resolved.title == "My Own Correct Title For This Paper")
        #expect(resolved.titleSource == .existing)
        #expect(resolved.author == nil)
        #expect(resolved.subject == nil)
        #expect(resolved.doi == nil)
        #expect(resolved.warnings.count == 1)
    }

    @Test func withoutLookupTitleComesFromLargestTextAndSubjectFromDOI() async {
        let resolved = await MetadataResolver(lookup: nil).resolve(jamaSnapshot)
        #expect(resolved.title == jamaTitle)
        #expect(resolved.titleSource == .content)
        #expect(resolved.author == nil)
        #expect(resolved.subject == "DOI: 10.1001/jamainternmed.2021.8098")
    }

    @Test func failedLookupFallsBackAndWarns() async {
        let resolved = await MetadataResolver(lookup: FakeLookup(fails: true)).resolve(jamaSnapshot)
        #expect(resolved.title == jamaTitle)
        #expect(resolved.titleSource == .content)
        #expect(resolved.doi == "10.1001/jamainternmed.2021.8098")
        #expect(resolved.warnings.count == 1)
    }

    @Test func goodExistingMetadataWithoutDOIIsLeftAlone() async {
        let snapshot = PDFSnapshot(
            existing: ExistingMetadata(title: "A Quandary of Wokeness", author: "Jane Doe", subject: "Journal of Controversial Ideas", keywords: ["ethics", "Ethics", "speech"]),
            pageTexts: ["A Quandary of Wokeness\nJane Doe"],
            firstPageRuns: [TextRun("Some Other Large Heading Text", fontSize: 30)]
        )
        let resolved = await MetadataResolver(lookup: FakeLookup(work: jamaWork)).resolve(snapshot)
        #expect(resolved.title == "A Quandary of Wokeness")
        #expect(resolved.titleSource == .existing)
        #expect(resolved.author == "Jane Doe")
        #expect(resolved.subject == "Journal of Controversial Ideas")
        #expect(resolved.keywords == ["ethics", "speech"])
    }

    @Test func existingSubjectIsKeptOverJournalName() async {
        var snapshot = jamaSnapshot
        snapshot.existing.subject = "Sleep research reading list"
        let resolved = await MetadataResolver(lookup: FakeLookup(work: jamaWork)).resolve(snapshot)
        #expect(resolved.subject == "Sleep research reading list")
    }

    @Test func doiPlaceholderSubjectIsUpgradedToJournalName() async {
        var snapshot = jamaSnapshot
        snapshot.existing.subject = "DOI: 10.1001/jamainternmed.2021.8098"
        let resolved = await MetadataResolver(lookup: FakeLookup(work: jamaWork)).resolve(snapshot)
        #expect(resolved.subject == "JAMA Internal Medicine")
    }

    @Test func corruptedExistingKeywordsAreReplacedFromKeywordSection() async {
        let snapshot = PDFSnapshot(
            existing: ExistingMetadata(title: "Chemsex and harm reduction among men in Australia", keywords: ["10.1111/dar.12536 and chemsex"]),
            pageTexts: ["Chemsex and harm reduction among men in Australia\nKeywords: chemsex; harm reduction\nIntroduction"]
        )
        let resolved = await MetadataResolver(lookup: nil).resolve(snapshot)
        #expect(resolved.keywords == ["chemsex", "harm reduction"])
    }
}

@Suite struct ChangePlanTests {
    func resolved(title: String?, author: String? = nil, subject: String? = nil, keywords: [String] = []) -> ResolvedMetadata {
        var r = ResolvedMetadata()
        r.title = title; r.author = author; r.subject = subject; r.keywords = keywords
        return r
    }

    @Test func listsOnlyFieldsThatDiffer() {
        let existing = ExistingMetadata(title: nil, author: "American Medical Association", subject: "Kept", keywords: ["The JAMA Network"])
        let plan = ChangePlan.make(currentFilename: "x.pdf", existing: existing,
                                   resolved: resolved(title: "New Title", author: "Esra Tasali", subject: "Kept"), exists: { _ in false })
        #expect(plan.changes == [
            FieldChange(field: "Title", old: nil, new: "New Title"),
            FieldChange(field: "Author", old: "American Medical Association", new: "Esra Tasali"),
            FieldChange(field: "Keywords", old: "The JAMA Network", new: nil),
        ])
    }

    @Test func proposesFilenameFromTitle() {
        let plan = ChangePlan.make(currentFilename: "jamainternal_tasali_2022.pdf", existing: .init(),
                                   resolved: resolved(title: "Sleep: A Trial"), exists: { _ in false })
        #expect(plan.newFilename == "Sleep - A Trial.pdf")
    }

    @Test func noRenameWhenNameAlreadyMatches() {
        let plan = ChangePlan.make(currentFilename: "Sleep - A Trial.pdf", existing: .init(title: "Sleep: A Trial"),
                                   resolved: resolved(title: "Sleep: A Trial"), exists: { _ in true })
        #expect(plan.changes == [])
        #expect(plan.newFilename == nil)
    }

    @Test func noRenameWhenNamesDifferOnlyByUnicodeNormalisation() {
        // Filenames read back from disk can be decomposed (u + combining macron) while titles are precomposed.
        let plan = ChangePlan.make(currentFilename: "Tu\u{0304} Whakaruruhau.pdf", existing: .init(),
                                   resolved: resolved(title: "T\u{016B} Whakaruruhau"), exists: { _ in false })
        #expect(plan.newFilename == nil)
    }

    @Test func numbersTheNameWhenAnotherFileAlreadyHasIt() {
        let taken: Set = ["Sleep.pdf", "Sleep (1).pdf"]
        let plan = ChangePlan.make(currentFilename: "download.pdf", existing: .init(),
                                   resolved: resolved(title: "Sleep"), exists: { taken.contains($0) })
        #expect(plan.newFilename == "Sleep (2).pdf")
    }

    @Test func noRenameWithoutATitle() {
        let plan = ChangePlan.make(currentFilename: "download.pdf", existing: .init(), resolved: resolved(title: nil), exists: { _ in false })
        #expect(plan.newFilename == nil)
    }
}

@Suite struct TitlePreservationTests {
    @Test func existingTitleIsNotClearedWhenNothingBetterIsFound() async {
        let existing = ExistingMetadata(title: "untitled")
        let resolved = await MetadataResolver(lookup: nil).resolve(PDFSnapshot(existing: existing))
        let plan = ChangePlan.make(currentFilename: "scan.pdf", existing: existing, resolved: resolved, exists: { _ in false })
        #expect(resolved.title == nil)
        #expect(plan.changes == [])
    }
}
