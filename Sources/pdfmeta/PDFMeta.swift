import ArgumentParser
import Foundation
import PDFMetadataCore

@main
struct PDFMeta: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pdfmeta",
        abstract: "Extract, fix, and rename PDFs with proper metadata.",
        subcommands: [Extract.self, ProcessAll.self, SetMetadata.self]
    )
}

struct InputOptions: ParsableArguments {
    @Argument(help: "A PDF file or a directory of PDFs.")
    var path: String

    @Flag(name: .shortAndLong, help: "Process directories recursively.")
    var recursive = false

    @Flag(name: .customLong("no-doi-lookup"), help: "Resolve offline, without asking CrossRef.")
    var noDOILookup = false

    func files() throws -> [URL] {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("No such file or directory: \(path)")
        }
        return PDFFinder.find(at: url, recursive: recursive)
    }

    var resolver: MetadataResolver {
        guard !noDOILookup else { return MetadataResolver(lookup: nil) }
        // CROSSREF_MAILTO opts in to CrossRef's faster "polite pool".
        let client = CrossRefClient(mailto: ProcessInfo.processInfo.environment["CROSSREF_MAILTO"])
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return MetadataResolver(lookup: CachingLookup(client, directory: caches.appendingPathComponent("pdfmeta/crossref")))
    }
}

struct Resolution: Sendable {
    var snapshot: PDFSnapshot
    var metadata: ResolvedMetadata
}

/// Reads and resolves `files` one at a time: CrossRef's public pool allows a single connection per client.
func resolve(_ files: [URL], with resolver: MetadataResolver, each: (URL, Result<Resolution, any Error>) -> Void) async {
    for file in files {
        do {
            let snapshot = try PDFReader.snapshot(of: file)
            each(file, .success(Resolution(snapshot: snapshot, metadata: await resolver.resolve(snapshot))))
        } catch {
            each(file, .failure(error))
        }
    }
}

struct Extract: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the metadata that would be used for each PDF.")

    @OptionGroup var input: InputOptions

    @Flag(help: "Print JSON instead of text.")
    var json = false

    private struct Entry: Encodable {
        let file: String
        let metadata: ResolvedMetadata?
        let error: String?
    }

    func run() async throws {
        var entries: [Entry] = []
        await resolve(try input.files(), with: input.resolver) { file, result in
            switch result {
            case .success(let resolution):
                entries.append(Entry(file: file.path, metadata: resolution.metadata, error: nil))
                if !json { printMetadata(resolution.metadata, for: file) }
            case .failure(let error):
                entries.append(Entry(file: file.path, metadata: nil, error: error.localizedDescription))
                if !json { print(Style.red("✗ \(file.lastPathComponent): \(error.localizedDescription)")) }
            }
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(entries), as: UTF8.self))
        }
    }

    private func printMetadata(_ metadata: ResolvedMetadata, for file: URL) {
        print(Style.bold(file.lastPathComponent))
        let rows: [(String, String?)] = [
            ("Title", metadata.title.map { "\($0) \(Style.dim("[\(metadata.titleSource.rawValue)]"))" }),
            ("Author", metadata.author),
            ("Subject", metadata.subject),
            ("Keywords", metadata.keywords.isEmpty ? nil : metadata.keywords.joined(separator: ", ")),
            ("DOI", metadata.doi),
            ("Year", metadata.year.map(String.init)),
        ]
        for (label, value) in rows {
            print("  \(label.column)\(value ?? Style.dim("—"))")
        }
        for warning in metadata.warnings { print(Style.yellow("  ⚠ \(warning)")) }
        print()
    }
}

struct ProcessAll: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "process-all",
        abstract: "Fix metadata and rename files."
    )

    @OptionGroup var input: InputOptions

    @Flag(name: .customLong("dry-run"), help: "Preview changes without applying them.")
    var dryRun = false

    @Flag(inversion: .prefixedNo, help: "Copy each PDF into a backups folder beside it before rewriting it.")
    var backup = true

    func run() async throws {
        let files = try input.files()
        var (updates, renames, warnings, failures, staleXMP) = (0, 0, 0, 0, 0)

        await resolve(files, with: input.resolver) { file, result in
            guard case .success(let resolution) = result else {
                if case .failure(let error) = result {
                    print(Style.red("✗ \(file.lastPathComponent): \(error.localizedDescription)"))
                }
                failures += 1
                return
            }
            let metadata = resolution.metadata
            let folder = file.deletingLastPathComponent()
            let plan = ChangePlan.make(currentFilename: file.lastPathComponent, existing: resolution.snapshot.existing, resolved: metadata) {
                FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
            }
            warnings += metadata.warnings.count

            if plan.changes.isEmpty, plan.newFilename == nil, metadata.warnings.isEmpty {
                print(Style.dim("✓ \(file.lastPathComponent)"))
                return
            }
            printPlan(plan, metadata: metadata, for: file)

            if !dryRun {
                do {
                    let applied = try ChangeApplier.apply(plan, metadata: metadata, to: file, backup: backup)
                    if applied.xmp == .unreadable {
                        print(Style.dim("  note: embedded XMP could not be updated and keeps its old values"))
                        staleXMP += 1
                    }
                } catch {
                    print(Style.red("  ✗ \(error.localizedDescription)"))
                    failures += 1
                    return
                }
            }
            if !plan.changes.isEmpty { updates += 1 }
            if plan.newFilename != nil { renames += 1 }
        }

        let (updated, renamed) = dryRun ? ("would update metadata in", "would rename") : ("updated metadata in", "renamed")
        print("\n\(dryRun ? "Dry run" : "Done"): \(files.count) PDFs · \(updated) \(updates) · \(renamed) \(renames) · \(warnings) warnings · \(failures) failed\(staleXMP > 0 ? " · \(staleXMP) with XMP left as is" : "")")
    }
}

/// Prints what a plan changes for one file.
func printPlan(_ plan: FilePlan, metadata: ResolvedMetadata, for file: URL) {
    print(Style.bold(file.lastPathComponent))
    for change in plan.changes {
        // Say where a new title came from: one read off the page deserves a second look.
        let source = change.field == "Title" ? Style.dim(" [\(metadata.titleSource.rawValue)]") : ""
        print("  \(change.field.column)\(Style.dim(change.old ?? "—")) → \(change.new ?? Style.dim("(cleared)"))\(source)")
    }
    if let name = plan.newFilename { print("  \("Rename".column)→ \(Style.green(name))") }
    for warning in metadata.warnings { print(Style.yellow("  ⚠ \(warning)")) }
}

struct SetMetadata: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Set metadata by hand for one PDF, for papers no registry knows. A new title also renames the file."
    )

    @Argument(help: "The PDF to change.")
    var path: String

    @Option(help: "New title.")
    var title: String?

    @Option(help: "New author string, e.g. \"A One, B Two, and C Three\".")
    var author: String?

    @Option(help: "New subject, usually the journal or kind of document.")
    var subject: String?

    @Option(help: "New keywords, separated by commas or semicolons.")
    var keywords: String?

    @Flag(name: .customLong("dry-run"), help: "Preview changes without applying them.")
    var dryRun = false

    @Flag(inversion: .prefixedNo, help: "Copy the PDF into a backups folder beside it before rewriting it.")
    var backup = true

    func run() throws {
        let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let existing = try PDFReader.snapshot(of: file).existing
        let metadata = ResolvedMetadata(keeping: existing, title: title, author: author, subject: subject,
                                        keywords: keywords.map(KeywordParser.split))
        let folder = file.deletingLastPathComponent()
        let plan = ChangePlan.make(currentFilename: file.lastPathComponent, existing: existing, resolved: metadata) {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
        guard !plan.changes.isEmpty || plan.newFilename != nil else {
            print(Style.dim("✓ \(file.lastPathComponent)"))
            return
        }
        printPlan(plan, metadata: metadata, for: file)
        if !dryRun {
            let applied = try ChangeApplier.apply(plan, metadata: metadata, to: file, backup: backup)
            if applied.xmp == .unreadable {
                print(Style.dim("  note: embedded XMP could not be updated and keeps its old values"))
            }
        }
    }
}

extension String {
    /// Padded to the width of the field-label column.
    var column: String { padding(toLength: 9, withPad: " ", startingAt: 0) }
}

/// ANSI styling, applied only when writing to a terminal.
enum Style {
    private static let enabled = isatty(STDOUT_FILENO) != 0

    private static func wrap(_ text: String, _ code: String) -> String {
        enabled ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    static func bold(_ text: String) -> String { wrap(text, "1") }
    static func dim(_ text: String) -> String { wrap(text, "2") }
    static func red(_ text: String) -> String { wrap(text, "31") }
    static func green(_ text: String) -> String { wrap(text, "32") }
    static func yellow(_ text: String) -> String { wrap(text, "33") }
}
