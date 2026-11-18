# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A tool that extracts, fixes, and enhances the metadata of academic PDFs for display in Books and Preview, and renames the files after their titles.

It is mid-migration from Python to Swift:

- **Swift (`pdfmeta`)** is where new work goes. It currently reads and previews only: `extract` and `process-all --dry-run`. Writing metadata and renaming files are not implemented.
- **Python (`pdf-metadata-tool`, under `src/`)** is the legacy implementation and still the only one that writes. Fix it only if asked; do not add features to it.

## Commands

### Swift
- `swift test` - Run the unit tests
- `swift build -c release` - Build the CLI
- `swift run -c release pdfmeta extract <path> [--json]` - Show resolved metadata
- `swift run -c release pdfmeta process-all <path> --dry-run` - Preview metadata changes and renames
- Shared flags: `-r/--recursive`, `--no-doi-lookup`

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
- **Text.swift** - HTML stripping and text normalisation helpers

### `Sources/pdfmeta` (CLI)

swift-argument-parser commands and terminal output only; no logic that needs testing lives here.

### Resolution rules

- A CrossRef record is trusted only when its title is found in the PDF's own text.
- Title precedence: confirmed CrossRef title, then a non-junk stored title, then the largest text on page 1.
- A stored title that matches CrossRef's apart from punctuation, case or a trailing footnote digit is kept.
- A failed lookup marks the result `isIncomplete`, and `ChangePlan` then proposes nothing for that file.
- Titles guessed from page content do not rename files that already have readable names.

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
- Before any feature that writes to PDFs is run on a real library, dry-run it and review the output.

## Python Architecture (legacy)

- **metadata_extractor.py** - Reads metadata (pypdf) and page text (pdfplumber); title, author, DOI and keyword heuristics
- **metadata_editor.py** - Writes metadata with pypdf, sets Preview-compatible keywords via exiftool, handles backups
- **file_renamer.py** - Builds "Title.pdf" filenames and resolves conflicts
- **doi_lookup.py** - CrossRef lookup
- **cli.py** - Click and Rich command-line interface
