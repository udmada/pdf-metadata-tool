import Foundation
import Testing
@testable import PDFMetadataCore

/// Cases found by dry-running against a real library of papers.
@Suite struct RealWorldDOITests {
    @Test func prefersCompleteDOIOverFragmentCutAtLineEnd() {
        let page = "Citation: Lisboa C (2023) e0287683. https://doi.org/10.1371/journal.\npone.0287683\nPLOS ONE | https://doi.org/10.1371/journal.pone.0287683 October 19, 2023"
        #expect(DOIFinder.find(in: [page]) == "10.1371/journal.pone.0287683")
    }

    @Test func prefersCompleteDOIFoundOnALaterPage() {
        #expect(DOIFinder.find(in: ["https://doi.org/10.3390/brainsci\n14070666", "Brain Sci. https://doi.org/10.3390/brainsci14070666 x"]) == "10.3390/brainsci14070666")
    }

    @Test func stripsLabelGluedOntoEndOfDOI() {
        #expect(DOIFinder.find(in: ["; https://doi.org/10.1101/2025.05.21.655261doi: bioRxiv preprint"]) == "10.1101/2025.05.21.655261")
    }
}

@Suite struct RealWorldCrossRefTests {
    @Test func ignoresRecordsForWholeJournals() throws {
        let json = Data(#"{"message":{"type":"journal","title":["Brain Sciences"]}}"#.utf8)
        #expect(try CrossRefWork.decode(from: json) == nil)
    }

    @Test func normalisesAuthorNamesRegisteredInCapitals() throws {
        let json = Data(#"{"message":{"type":"journal-article","title":["Sex in Prisoner Power Relations"],"author":[{"given":"ANTON","family":"SYMKOVYCH"},{"given":"J. M.","family":"Bailey"}]}}"#.utf8)
        #expect(try CrossRefWork.decode(from: json)?.authors == ["Anton Symkovych", "J. M. Bailey"])
    }
}

@Suite struct RealWorldResolverTests {
    func snapshot(existingTitle: String, printed: String) -> PDFSnapshot {
        PDFSnapshot(existing: ExistingMetadata(title: existingTitle), pageTexts: ["\(printed)\ndoi:10.1234/example.1"])
    }

    @Test(arguments: [
        ("Don't Worry, Be Happy: The Gettability of Ultimate Meaning", "Don’t Worry, Be Happy: The Gettability of Ultimate Meaning"),
        ("Pronoun Problems and Their Many Solutions", "Pronoun Problems and Their Many Solutions1"),
        ("Breeding futures: ethics in Treasure Island Media’s Viral Loads", "Breeding futures: ethics in Treasure Island Media’sViral Loads"),
        ("An Internet study of men: Correlates of offending", "An Internet study of men: Correlates of offending."),
    ])
    func keepsExistingTitleThatDiffersFromRegistryOnlyCosmetically(existing: String, registered: String) async {
        let lookup = FakeLookup(work: CrossRefWork(title: registered, authors: ["A B"]))
        let resolved = await MetadataResolver(lookup: lookup).resolve(snapshot(existingTitle: existing, printed: existing))
        #expect(resolved.title == existing)
        #expect(resolved.author == "A B")
    }

    @Test func replacesExistingTitleThatWasTruncated() async {
        let full = "Fun with Friends? Participation in the Gay Community Predicts Alcohol and Drug Consumption"
        let lookup = FakeLookup(work: CrossRefWork(title: full))
        let resolved = await MetadataResolver(lookup: lookup).resolve(snapshot(existingTitle: "Fun with Friends? Participation in the Gay Commu", printed: full))
        #expect(resolved.title == full)
        #expect(resolved.titleSource == .crossref)
    }

    @Test func removesSoftHyphensFromKeywords() {
        #expect(KeywordParser.keywords(in: "Keywords: feminism; gender non\u{00AD}conformity") == ["feminism", "gender nonconformity"])
    }
}

@Suite struct ContentTitleRenameTests {
    func plan(currentFilename: String, source: MetadataSource) -> FilePlan {
        var resolved = ResolvedMetadata()
        resolved.title = "Navigating Uncertainty in Search of the Good Life"
        resolved.titleSource = source
        return ChangePlan.make(currentFilename: currentFilename, existing: .init(), resolved: resolved, exists: { _ in false })
    }

    @Test func guessedTitleDoesNotRenameAFileSomeoneAlreadyNamed() {
        #expect(plan(currentFilename: "Chemical Youth.pdf", source: .content).newFilename == nil)
    }

    @Test func guessedTitleRenamesAMachineNamedFile() {
        #expect(plan(currentFilename: "492429_1_En_Print.pdf", source: .content).newFilename == "Navigating Uncertainty in Search of the Good Life.pdf")
    }

    @Test func storedTitleDoesNotRenameAFileSomeoneAlreadyNamed() {
        // Once written, a guessed title reads back as a stored one; it must not gain the power to rename.
        #expect(plan(currentFilename: "Chemical Youth.pdf", source: .existing).newFilename == nil)
    }

    @Test func confirmedTitleRenamesAFileSomeoneAlreadyNamed() {
        #expect(plan(currentFilename: "Chemical Youth.pdf", source: .crossref).newFilename == "Navigating Uncertainty in Search of the Good Life.pdf")
    }
}

actor CountingLookup: DOILookup {
    private(set) var calls = 0
    let work: CrossRefWork?
    let fails: Bool

    init(work: CrossRefWork?, fails: Bool = false) {
        self.work = work
        self.fails = fails
    }

    func lookup(doi: String) async throws -> CrossRefWork? {
        calls += 1
        if fails { throw FakeLookup.Failure() }
        return work
    }
}

@Suite struct CachingLookupTests {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pdfmeta-cache-\(UUID().uuidString)")

    @Test func secondLookupIsServedFromDisk() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let network = CountingLookup(work: CrossRefWork(title: "Cached Title", authors: ["A B"], journal: "J", year: 2020))
        let first = try await CachingLookup(network, directory: directory).lookup(doi: "10.1234/a/b(c)")
        let second = try await CachingLookup(network, directory: directory).lookup(doi: "10.1234/a/b(c)")
        #expect(first == second)
        #expect(second?.title == "Cached Title")
        #expect(await network.calls == 1)
    }

    @Test func remembersThatADOIIsUnregistered() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let network = CountingLookup(work: nil)
        let cache = CachingLookup(network, directory: directory)
        #expect(try await cache.lookup(doi: "10.1234/missing") == nil)
        #expect(try await cache.lookup(doi: "10.1234/missing") == nil)
        #expect(await network.calls == 1)
    }

    @Test func failuresAreNotCached() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let network = CountingLookup(work: nil, fails: true)
        let cache = CachingLookup(network, directory: directory)
        _ = try? await cache.lookup(doi: "10.1234/flaky")
        _ = try? await cache.lookup(doi: "10.1234/flaky")
        #expect(await network.calls == 2)
    }

    @Test func differentDOIsDoNotShareAnEntry() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let network = CountingLookup(work: CrossRefWork(title: "T"))
        let cache = CachingLookup(network, directory: directory)
        _ = try await cache.lookup(doi: "10.1234/a.b")
        _ = try await cache.lookup(doi: "10.1234/a/b")
        #expect(await network.calls == 2)
    }
}

@Suite struct SafetyTests {
    @Test func nothingIsChangedForAFileWhoseLookupFailed() async {
        // Acting on a partial answer would swap good registry data for guesses on the next transient outage.
        let resolved = await MetadataResolver(lookup: FakeLookup(fails: true)).resolve(jamaSnapshot)
        let plan = ChangePlan.make(currentFilename: "jama.pdf", existing: jamaSnapshot.existing, resolved: resolved, exists: { _ in false })
        #expect(resolved.isIncomplete)
        #expect(plan == FilePlan(changes: [], newFilename: nil))
    }

    @Test func completedLookupIsNotMarkedIncomplete() async {
        let resolved = await MetadataResolver(lookup: FakeLookup(work: jamaWork)).resolve(jamaSnapshot)
        #expect(!resolved.isIncomplete)
    }

    @Test func fileIsNotRenamedToACutOffVersionOfItsOwnName() {
        var resolved = ResolvedMetadata()
        resolved.title = "“Where Is My Place?” A Qualitative Study of Gay Men’s Experiences of Social Support, Relationships a"
        resolved.titleSource = .existing
        let current = "“ Where Is My Place” A Qualitative Study of Gay Men’s Experiences of Social Support, Relationships and Community.pdf"
        #expect(ChangePlan.make(currentFilename: current, existing: .init(), resolved: resolved, exists: { _ in false }).newFilename == nil)
    }
}

/// Answers only for the DOIs it knows, like the real registry.
struct MapLookup: DOILookup {
    var works: [String: CrossRefWork]

    func lookup(doi: String) async throws -> CrossRefWork? { works[doi] }
}

@Suite struct SecondPassTests {
    @Test func registryTitleReplacesStoredTitleThatCameFromAFilename() async {
        // "_" standing in for ":" is the mark of a title copied from a sanitised filename.
        let snapshot = PDFSnapshot(existing: ExistingMetadata(title: "Pharmacosex_ Reimagining sex, drugs and enhancement"),
                                   pageTexts: ["Pharmacosex: Reimagining sex, drugs and enhancement\ndoi:10.1234/example.1"])
        let lookup = FakeLookup(work: CrossRefWork(title: "Pharmacosex: Reimagining sex, drugs and enhancement"))
        let resolved = await MetadataResolver(lookup: lookup).resolve(snapshot)
        #expect(resolved.title == "Pharmacosex: Reimagining sex, drugs and enhancement")
    }

    @Test func retriesUnregisteredDOIWithoutWordsGluedOntoItsEnd() async {
        let title = "Comparative phylogenetic analyses uncover the ancient roots of Indo-European folktales"
        let snapshot = PDFSnapshot(pageTexts: ["Comparativephylogenetic analysesuncoverthe ancientrootsof Indo-Europeanfolktales\nhttps://doi.org/10.1098/rsos.150645orvia http://rsos.royalsocietypublishing.org"])
        let resolved = await MetadataResolver(lookup: MapLookup(works: ["10.1098/rsos.150645": CrossRefWork(title: title)])).resolve(snapshot)
        #expect(resolved.title == title)
        #expect(resolved.doi == "10.1098/rsos.150645")
        #expect(resolved.warnings == [])
    }

    @Test func unregisteredDOIStillWarnsWhenRetryFindsNothing() async {
        let snapshot = PDFSnapshot(pageTexts: ["A Paper\ndoi:10.1098/rsos.150645orvia"])
        let resolved = await MetadataResolver(lookup: MapLookup(works: [:])).resolve(snapshot)
        #expect(resolved.doi == "10.1098/rsos.150645orvia")
        #expect(resolved.warnings.count == 1)
    }

    @Test func extractedTitleDropsDanglingPunctuation() {
        let runs = [TextRun("The Employment Contracts Act 1991:\n", fontSize: 20), TextRun("a history of its passage", fontSize: 14)]
        #expect(TitleExtractor.title(from: runs) == "The Employment Contracts Act 1991")
    }
}

@Suite struct ManualMetadataTests {
    let stored = ExistingMetadata(title: "An In-Depth Analysis", author: "An In and Depth Analysis", subject: "Kept Subject", keywords: ["kept"])

    @Test func givenFieldsReplaceStoredOnesAndTheRestAreKept() {
        let manual = ResolvedMetadata(keeping: stored, title: "Hatescape: An In-Depth Analysis", author: "Ciarán O’Connor")
        #expect(manual.title == "Hatescape: An In-Depth Analysis")
        #expect(manual.author == "Ciarán O’Connor")
        #expect(manual.subject == "Kept Subject")
        #expect(manual.keywords == ["kept"])
        #expect(manual.titleSource == .manual)
    }

    @Test func withoutANewTitleTheStoredOneKeepsItsStanding() {
        let manual = ResolvedMetadata(keeping: stored, author: "Ciarán O’Connor")
        #expect(manual.title == "An In-Depth Analysis")
        #expect(manual.titleSource == .existing)
    }

    @Test func anEmptyValueClearsTheField() {
        let manual = ResolvedMetadata(keeping: stored, author: "", subject: "  ", keywords: [])
        #expect(manual.author == nil)
        #expect(manual.subject == nil)
        #expect(manual.keywords == [])
        #expect(manual.title == "An In-Depth Analysis")
    }

    @Test func aTitleTypedByAPersonRenamesAReadablyNamedFile() {
        let manual = ResolvedMetadata(keeping: stored, title: "Hatescape: An In-Depth Analysis")
        let plan = ChangePlan.make(currentFilename: "An In-Depth Analysis.pdf", existing: stored, resolved: manual, exists: { _ in false })
        #expect(plan.newFilename == "Hatescape - An In-Depth Analysis.pdf")
        #expect(plan.changes == [FieldChange(field: "Title", old: "An In-Depth Analysis", new: "Hatescape: An In-Depth Analysis")])
    }
}

@Suite struct LigatureTests {
    // PDFKit turns some fonts' "fi"/"fl" ligature glyphs into a space; the same word spelled
    // out elsewhere on the page shows how to rejoin it.
    let page = """
    Key words: homosexual, human immunode ciency virus, harm re ection, needle exchange.
    Introduction
    Gay and bisexual men are at risk of human immunodeficiency virus (HIV) and self-reflection matters.
    """

    @Test func rejoinsWordsSplitByALostLigature() {
        #expect(KeywordParser.keywords(in: page) == ["homosexual", "human immunodeficiency virus", "harm reflection", "needle exchange"])
    }

    @Test func leavesWordsAloneWhenThePageNeverSpellsThemOut() {
        #expect(KeywordParser.keywords(in: "Keywords: immunode ciency, needle exchange\nIntroduction") == ["immunode ciency", "needle exchange"])
    }

    @Test func doesNotJoinOrdinaryNeighbouringWords() {
        #expect(HTMLText.rejoiningLigatures("high field strength", vocabulary: ["highfield", "field"]) == "high field strength")
    }
}

@Suite struct GluedKeywordTests {
    @Test func storedKeywordsRunTogetherAreReplacedByThePrintedOnes() async {
        let snapshot = PDFSnapshot(
            existing: ExistingMetadata(title: "Sexual health practices of 16 to 19 year olds in New Zealand", keywords: ["youngpeople", "sexualbehaviour", "stiprevention"]),
            pageTexts: ["KEYWORDS: Young people; sexual behaviour; STI prevention; New Zealand\n64"])
        let resolved = await MetadataResolver(lookup: nil).resolve(snapshot)
        #expect(resolved.keywords == ["Young people", "sexual behaviour", "STI prevention", "New Zealand"])
    }

    @Test func storedKeywordsThatAreFineAreKept() async {
        let snapshot = PDFSnapshot(
            existing: ExistingMetadata(title: "A paper about sleep and energy", keywords: ["sleep", "obesity"]),
            pageTexts: ["Keywords: sleep; energy intake\nIntroduction"])
        let resolved = await MetadataResolver(lookup: nil).resolve(snapshot)
        #expect(resolved.keywords == ["sleep", "obesity"])
    }

    @Test func thornAfterAnAcronymIsAPlusSign() {
        // Some publisher fonts map "+" to the glyph for "þ".
        #expect(KeywordParser.keywords(in: "KEYWORDS: LGBTQþ communities; older adults\nIntroduction") == ["LGBTQ+ communities", "older adults"])
        #expect(KeywordParser.keywords(in: "Keywords: þorrablót; Iceland\nIntroduction") == ["þorrablót", "Iceland"])
    }
}

@Suite struct WrappedKeywordTests {
    let page = "KEYWORDS\nGay community; non-\nheterosexual males; LGBTQI\nþ; Eastern Europe; anti-\ngender mobilizations\nIntroduction"

    @Test func joinsHyphenatedAndAcronymLineBreaksWithoutASpace() {
        #expect(KeywordParser.keywords(in: page) == ["Gay community", "non-heterosexual males", "LGBTQI+", "Eastern Europe", "anti-gender mobilizations"])
    }

    @Test func dropsTheHyphenOfAWordBrokenAcrossLinesWhenThePageSpellsItWhole() {
        let page = "Keywords: genetic factors; sub-\nstance disorder; non-\nheterosexual males\nIntroduction\nSubstances used by non-heterosexual men."
        #expect(KeywordParser.keywords(in: page) == ["genetic factors", "substance disorder", "non-heterosexual males"])
    }

    @Test func goodStoredKeywordsAreNotMistakenForRunTogetherOnes() async {
        let stored = ["Gay community", "non-heterosexual males", "LGBTQI+", "Eastern Europe", "anti-gender mobilizations"]
        let snapshot = PDFSnapshot(existing: ExistingMetadata(title: "A Community Sounds Like Communism", keywords: stored),
                                   pageTexts: ["Keywords: e- health; LGBTQI +; Gay community\nIntroduction"])
        #expect(await MetadataResolver(lookup: nil).resolve(snapshot).keywords == stored)
    }
}
