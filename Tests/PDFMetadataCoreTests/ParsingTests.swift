import Foundation
import Testing
@testable import PDFMetadataCore

@Suite struct DOIFinderTests {
    @Test func findsLabelledDOI() {
        #expect(DOIFinder.find(in: ["JAMA Intern Med. doi:10.1001/jamainternmed.2021.8098\nPublished online"]) == "10.1001/jamainternmed.2021.8098")
    }

    @Test func stripsTrailingPunctuationFromURLForm() {
        #expect(DOIFinder.find(in: ["see https://doi.org/10.1016/j.drugpo.2020.102345."]) == "10.1016/j.drugpo.2020.102345")
    }

    @Test func findsUnlabelledDOIOnFirstPage() {
        #expect(DOIFinder.find(in: ["Addiction 10.1111/add.15123 Research report"]) == "10.1111/add.15123")
    }

    @Test func ignoresUnlabelledDOIOnLaterPages() {
        // A bare DOI past page 1 is far more likely a cited reference than this paper.
        #expect(DOIFinder.find(in: ["A paper with no identifier", "Smith J. Other work. 10.1111/add.99999"]) == nil)
    }

    @Test func returnsNilWithoutDOI() {
        #expect(DOIFinder.find(in: ["Version 10.2 of the software", ""]) == nil)
    }
}

@Suite struct CrossRefWorkTests {
    static let json = Data("""
    {"status":"ok","message":{
      "title":["Factors associated with HIV in <i>n</i> = 6059 men &amp; others"],
      "subtitle":["A Randomized Clinical Trial"],
      "author":[{"given":"Esra","family":"Tasali"},{"family":"Wroblewski","given":"Kristen"},{"name":"The FLUX Study Group"}],
      "container-title":["JAMA Internal Medicine"],
      "published-print":{"date-parts":[[2022,4,1]]}
    }}
    """.utf8)

    @Test func decodesTitleStrippingMarkup() throws {
        let work = try #require(try CrossRefWork.decode(from: Self.json))
        #expect(work.title == "Factors associated with HIV in n = 6059 men & others")
    }

    @Test func decodesAuthorsIncludingGroupNames() throws {
        let work = try #require(try CrossRefWork.decode(from: Self.json))
        #expect(work.authors == ["Esra Tasali", "Kristen Wroblewski", "The FLUX Study Group"])
    }

    @Test func decodesJournalAndYear() throws {
        let work = try #require(try CrossRefWork.decode(from: Self.json))
        #expect(work.journal == "JAMA Internal Medicine")
        #expect(work.year == 2022)
    }

    @Test func returnsNilWhenRecordHasNoTitle() throws {
        #expect(try CrossRefWork.decode(from: Data(#"{"message":{"title":[]}}"#.utf8)) == nil)
    }

    @Test func fullTitleAppendsSubtitle() {
        let work = CrossRefWork(title: "Effect of Sleep Extension", subtitle: "A Randomized Clinical Trial")
        #expect(work.fullTitle == "Effect of Sleep Extension: A Randomized Clinical Trial")
    }

    @Test func fullTitleDoesNotRepeatSubtitleAlreadyInTitle() {
        let work = CrossRefWork(title: "Effect of Sleep Extension: a randomized clinical trial", subtitle: "A Randomized Clinical Trial")
        #expect(work.fullTitle == "Effect of Sleep Extension: a randomized clinical trial")
    }
}

@Suite struct TitleMatcherTests {
    let title = "Effect of Sleep Extension on Objectively Assessed Energy Intake Among Adults With Overweight in Real-life Settings"

    @Test func matchesTitlePresentOnPage() {
        #expect(TitleMatcher.matches(title: title, pageText: "Research\n\(title)\nEsra Tasali, MD"))
    }

    @Test func matchesWhenPageTextHasNoWordSpacing() {
        let page = "EffectofSleepExtensiononObjectivelyAssessedEnergyIntake\nAmongAdultsWithOverweightinReal-lifeSettings"
        #expect(TitleMatcher.matches(title: title, pageText: page))
    }

    @Test func matchesAcrossLineBreaksAndPunctuationDifferences() {
        let page = "Destabilising the ‘problem’ of chemsex:\nDiversity in settings, relations and practices"
        #expect(TitleMatcher.matches(title: "Destabilising the 'problem' of chemsex - diversity in settings, relations and practices", pageText: page))
    }

    @Test func rejectsTitleOfADifferentPaper() {
        let page = "Methamphetamine use and associated factors among people who inject drugs in Iran"
        #expect(!TitleMatcher.matches(title: title, pageText: page))
    }

    @Test func rejectsEmptyTitle() {
        #expect(!TitleMatcher.matches(title: "", pageText: "anything"))
    }
}

@Suite struct AuthorFormatterTests {
    @Test func noAuthorsGivesNil() { #expect(AuthorFormatter.format([]) == nil) }
    @Test func singleAuthor() { #expect(AuthorFormatter.format(["John Smith"]) == "John Smith") }
    @Test func twoAuthorsJoinedWithAnd() { #expect(AuthorFormatter.format(["John Smith", "Jane Doe"]) == "John Smith and Jane Doe") }
    @Test func threeAuthorsUseSerialComma() {
        #expect(AuthorFormatter.format(["John Smith", "Jane Doe", "Bob Johnson"]) == "John Smith, Jane Doe, and Bob Johnson")
    }
    @Test func moreThanFiveAuthorsAreAbbreviated() {
        #expect(AuthorFormatter.format(["A A", "B B", "C C", "D D", "E E", "F F"]) == "A A, B B, C C, D D, E E, et al.")
    }
}

@Suite struct TitleExtractorTests {
    @Test func picksLargestMultiWordRun() {
        let runs = [
            TextRun("Research\nJAMA Internal Medicine | Original Investigation", fontSize: 9),
            TextRun("Effect of Sleep Extension on Objectively Assessed Energy Intake\nAmong Adults With Overweight", fontSize: 15),
            TextRun("Esra Tasali, MD; Kristen Wroblewski, MS", fontSize: 7.5),
        ]
        #expect(TitleExtractor.title(from: runs) == "Effect of Sleep Extension on Objectively Assessed Energy Intake Among Adults With Overweight")
    }

    @Test func ignoresLargeButShortRunsLikeSectionBanners() {
        let runs = [TextRun("Research", fontSize: 30), TextRun("A genome-wide association study of methamphetamine use", fontSize: 14)]
        #expect(TitleExtractor.title(from: runs) == "A genome-wide association study of methamphetamine use")
    }

    @Test func joinsAdjacentRunsOfTheSameSize() {
        // An italic word mid-title arrives as its own run with a different font but the same size.
        let runs = [TextRun("Effects of ", fontSize: 16), TextRun("N", fontSize: 16), TextRun("-isopropylbenzylamine in rodents", fontSize: 16), TextRun("Body text here", fontSize: 9)]
        #expect(TitleExtractor.title(from: runs) == "Effects of N-isopropylbenzylamine in rodents")
    }

    @Test func returnsNilWhenNothingLooksLikeATitle() {
        #expect(TitleExtractor.title(from: [TextRun("12", fontSize: 40)]) == nil)
    }
}

@Suite struct KeywordParserTests {
    @Test func parsesSemicolonSeparatedLine() {
        #expect(KeywordParser.keywords(in: "Abstract text.\nKeywords: chemsex; methamphetamine; HIV\nIntroduction") == ["chemsex", "methamphetamine", "HIV"])
    }

    @Test func joinsKeywordThatWrapsOntoNextLine() {
        let text = "Keywords: chemsex, methamphetamine, men who have sex with\nmen, HIV prevention\nIntroduction\nChemsex is"
        #expect(KeywordParser.keywords(in: text) == ["chemsex", "methamphetamine", "men who have sex with men", "HIV prevention"])
    }

    @Test func trailingPeriodEndsTheList() {
        let text = "KEYWORDS: sleep; obesity; energy intake.\nShort sleep is common, widespread; and getting worse"
        #expect(KeywordParser.keywords(in: text) == ["sleep", "obesity", "energy intake"])
    }

    @Test func parsesOneKeywordPerLineLayout() {
        let text = "Keywords:\nMethamphetamine\nChemsex\nHarm reduction\nAbstract\nBackground: Methamphetamine use is rising."
        #expect(KeywordParser.keywords(in: text) == ["Methamphetamine", "Chemsex", "Harm reduction"])
    }

    @Test func dropsCaseInsensitiveDuplicates() {
        #expect(KeywordParser.keywords(in: "Keywords: HIV, hiv, PrEP") == ["HIV", "PrEP"])
    }

    @Test func returnsEmptyWithoutAKeywordSection() {
        #expect(KeywordParser.keywords(in: "IMPORTANCE Short sleep duration\nThe keywords of the debate were unclear.") == [])
    }

    @Test func splitsRawMetadataStringOnSemicolonsBeforeCommas() {
        #expect(KeywordParser.split("HIV, AIDS; chemsex ;PrEP.") == ["HIV, AIDS", "chemsex", "PrEP"])
    }

    @Test func splitsRawMetadataStringOnCommas() {
        #expect(KeywordParser.split("HIV, chemsex,PrEP") == ["HIV", "chemsex", "PrEP"])
    }
}

@Suite struct BoilerplateTests {
    @Test(arguments: ["", "untitled", "Microsoft Word - draft_v3.docx", "jamainternal_tasali_2022_oi_210090", "PII: S0955-3959(20)30123-4", "doi:10.1016/j.drugpo.2020.102345", "EffectofSleepExtensiononObjectivelyAssessedEnergyIntake"])
    func recognisesJunkTitles(_ title: String) {
        #expect(Boilerplate.isJunkTitle(title))
    }

    @Test(arguments: ["The nature of chemsex", "A Quandary of Wokeness", "Absolute Backdoor Revisited", "Journal article reading habits among students"])
    func keepsRealTitles(_ title: String) {
        #expect(!Boilerplate.isJunkTitle(title))
    }

    @Test(arguments: ["American Medical Association", "Elsevier Ltd", "Springer Nature", "John Wiley & Sons"])
    func recognisesPublishersAsAuthors(_ author: String) {
        #expect(Boilerplate.isPublisherAuthor(author))
    }

    @Test func keepsPeopleAsAuthors() {
        #expect(!Boilerplate.isPublisherAuthor("Esra Tasali and Kristen Wroblewski"))
    }

    @Test func recognisesPublisherBrandingKeyword() {
        #expect(Boilerplate.isPublisherKeyword("The JAMA Network"))
        #expect(!Boilerplate.isPublisherKeyword("sleep extension"))
    }

    @Test(arguments: [["10.1111/dar.12536 and chemsex"], ["J. Thou Shalt Not Create", "4(1)", "6"], ["exchange [1, 4]"], ["needle exchange. and mixing characteristics"]])
    func recognisesCorruptedKeywords(_ keywords: [String]) {
        #expect(Boilerplate.keywordsLookCorrupted(keywords))
    }

    @Test func cleanKeywordsAreNotCorrupted() {
        #expect(!Boilerplate.keywordsLookCorrupted(["chemsex", "HIV pre-exposure prophylaxis", "U.S. cohort"]))
    }
}

@Suite struct FilenameBuilderTests {
    @Test func replacesColonWithDash() {
        #expect(FilenameBuilder.filename(forTitle: "Consent and violence: A scoping review") == "Consent and violence - A scoping review.pdf")
    }

    @Test func removesCharactersForbiddenInFilenames() {
        #expect(FilenameBuilder.filename(forTitle: "STI/HIV center: what \"works\"?") == "STIHIV center - what works.pdf")
    }

    @Test func stripsMarkupAndDecodesEntities() {
        #expect(FilenameBuilder.filename(forTitle: "Cohort of <i>n</i> = 6059 men &amp; women") == "Cohort of n = 6059 men & women.pdf")
    }

    @Test func returnsNilWithoutATitle() {
        #expect(FilenameBuilder.filename(forTitle: nil) == nil)
        #expect(FilenameBuilder.filename(forTitle: "  . ") == nil)
    }

    @Test func truncatesLongTitlesAtAWordBoundary() throws {
        let name = try #require(FilenameBuilder.filename(forTitle: String(repeating: "methamphetamine ", count: 30)))
        #expect(name.count <= 200)
        #expect(name.hasSuffix("methamphetamine....pdf"))
    }
}
