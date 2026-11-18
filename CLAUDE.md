# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A tool that extracts, fixes, and enhances the metadata of academic PDFs for display in Books and Preview, and renames the files after their titles.

It has been rewritten from Python to Swift:

- **Swift (`pdfmeta`)** is the tool and where all work goes: `extract`, and `process-all` with or without `--dry-run`.
- **Python (`pdf-metadata-tool`, under `src/`)** is the legacy implementation, kept for reference. Fix it only if asked; do not add features to it.

## Commands

### Swift
- `swift test` - Run the unit tests
- `swift build -c release` - Build the CLI
- `swift run -c release pdfmeta extract <path> [--json]` - Show resolved metadata
- `swift run -c release pdfmeta process-all <path> --dry-run` - Preview metadata changes and renames
- `swift run -c release pdfmeta process-all <path> [--no-backup]` - Apply them
- `swift run -c release pdfmeta set <file> [--title] [--author] [--subject] [--keywords]` - Set fields by hand for a paper CrossRef does not know; a new title renames the file
- Shared flags: `-r/--recursive`, `--no-doi-lookup`

Never run `process-all` without `--dry-run` on the user's real library unless they ask for that run; try changes on copies.

### CI
- Workflows are written in Pkl under `.github/pkl/` (pkl-pantry `com.github.actions`); the YAML in `.github/workflows/` and `.github/dependabot.yml` is generated. Never edit the YAML by hand.
- `mise run pkl:gen` regenerates it. A new action version gets its commit SHA resolved and recorded in `.github/workflows/__lockfile__.yml`, which Dependabot keeps up to date.
- `build.yml` runs on every push: tests, then a universal (arm64 + x86_64) macOS binary uploaded as the `pdfmeta-macos-universal` artifact. Pushing a `v*` tag also publishes it as a GitHub release.
- `pkl-check.yml` fails if the committed YAML differs from what the Pkl sources generate.

### Python (legacy)
- `uv sync` - Install dependencies
- `uv run pdf-metadata-tool <extract|rename|fix-metadata|process-all> <path> [--dry-run]`

## Swift Architecture

SwiftPM package at the repo root.

### `Sources/PDFMetadataCore` (library)

Everything except `PDFReader` is pure and works on plain values, so it is tested without PDF files.

- **Models.swift** - `PDFSnapshot` (what was read from a PDF), `ResolvedMetadata`, `CrossRefWork`, `FilePlan`, the `DOILookup` protocol
- **PDFReader.swift** - PDFKit boundary: info dictionary, text of the first pages, first-page text runs with font sizes. Also `PDFFinder` for locating PDFs
- **DOIFinder.swift** - Finds the paper's own DOI in page text
- **CrossRef.swift** - Response decoding, `CrossRefClient` (network), `CachingLookup` (disk cache)
- **Heuristics.swift** - `TitleMatcher`, `TitleExtractor` (largest text on page 1), `AuthorFormatter`, `Boilerplate` (junk titles, publisher names, corrupted keywords)
- **KeywordParser.swift** - Parses an explicit "Keywords" section
- **Planning.swift** - `MetadataResolver` (combines the sources), `ChangePlan` (field changes and rename for one file), `FilenameBuilder`
- **Applying.swift** - `PDFWriter` (PDFKit rewrite to a staging file, verified before it replaces the original), `FileOperations` (backup, rename), `ChangeApplier` (carries out a `FilePlan`)
- **XMP.swift** - `XMPPacket` (reads and edits the XMP XML with `XMLDocument`), `PDFXMP` (finds the catalog's metadata stream and replaces it by appending an incremental update). PDFKit never touches XMP, so `PDFWriter` calls these on the file PDFKit just wrote. `PDFXMP` only parses classic cross-reference tables, which is all PDFKit emits; do not point it at arbitrary PDFs and expect an answer
- **Text.swift** - HTML stripping and text normalisation helpers

### `Sources/pdfmeta` (CLI)

swift-argument-parser commands and terminal output only; no logic that needs testing lives here.

### Resolution rules

- A CrossRef record is trusted only when its title is found in the PDF's own text.
- Title precedence: confirmed CrossRef title, then a non-junk stored title, then the largest text on page 1.
- A stored title that matches CrossRef's apart from punctuation, case or a trailing footnote digit is kept.
- A failed lookup marks the result `isIncomplete`, and `ChangePlan` then proposes nothing for that file.
- Only a CrossRef-confirmed title renames a file that already has a readable name. Stored and guessed titles do not, which also keeps a second run from acting on a guess the first run wrote.
- Applying must be idempotent: a second `process-all` over the same files changes nothing.

### Author Format Standards

Books has a single author string, so authors are formatted as:
- Single author: "John Smith"
- Two authors: "John Smith and Jane Doe"
- Three to five authors: "John Smith, Jane Doe, and Bob Johnson"
- More than five: first five, then "et al."

## Testing Approach

- Tests use Swift Testing (`import Testing`) and are written before the code they cover.
- `RegressionTests.swift` holds cases found by dry-running against a real library of papers; when a dry run turns up a wrong result, add the case there first.
- `PDFReaderTests` generate their PDFs with CoreGraphics at run time; `*.pdf` is gitignored, so do not rely on fixture files.
- CrossRef is never called from tests; use the fake lookups in the test target.
- Run the suite under a hard time limit (it finishes in under a second). The machine's disk is nearly full, and a runaway allocation in a test once filled it with swap within seconds. Never concatenate onto an unbounded lazy sequence (`[x] + (1...).lazy.map`): `+` builds a real array.
- Before any feature that writes to PDFs is run on a real library, dry-run it and review the output.

## Python Architecture (legacy)

- **metadata_extractor.py** - Reads metadata (pypdf) and page text (pdfplumber); title, author, DOI and keyword heuristics
- **metadata_editor.py** - Writes metadata with pypdf, sets Preview-compatible keywords via exiftool, handles backups
- **file_renamer.py** - Builds "Title.pdf" filenames and resolves conflicts
- **doi_lookup.py** - CrossRef lookup
- **cli.py** - Click and Rich command-line interface
