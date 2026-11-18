# pdf-metadata-tool

Fixes the metadata of academic PDFs so they show up properly in Books and Preview, and renames the files after their titles.

The tool is being rewritten from Python to Swift. The Swift version (`pdfmeta`) reads PDFs and previews what it would change; it does not write yet. The original Python version still does the writing and renaming.

| | Swift `pdfmeta` | Python `pdf-metadata-tool` |
|---|---|---|
| Extract metadata | yes | yes |
| Preview changes (`--dry-run`) | yes | yes |
| Write metadata, rename files | not yet | yes |
| Requires | macOS 14+, Swift 6 | uv, exiftool |

## Swift: `pdfmeta`

```sh
swift build -c release
swift run -c release pdfmeta extract paper.pdf
swift run -c release pdfmeta process-all ~/Papers --dry-run
swift test
```

Options for both commands:

- `-r`, `--recursive`: descend into subfolders (folders named `backups` are skipped)
- `--no-doi-lookup`: work offline, without asking CrossRef
- `extract --json`: machine-readable output

### How metadata is chosen

1. The paper's DOI is read from its first three pages.
2. CrossRef is asked about that DOI. Its answer is used only if the title it returns is found printed in the PDF, which rules out DOIs that belong to a cited reference.
3. A confirmed CrossRef record supplies the title (with subtitle), authors, journal and year.
4. Without one, the stored title is kept unless it is junk (`untitled`, `Microsoft Word - ...`, a filename). Failing that, the title is the largest multi-word text on page 1; the preview marks such titles `[content]`.
5. Publisher boilerplate is dropped from the author and keywords fields. Keywords are otherwise only taken from an explicit "Keywords" section.

A stored title that differs from CrossRef's only in punctuation, case or a trailing footnote number is kept as it is.

Authors are written as one string, the form Books displays best: `A`, `A and B`, `A, B, and C`, and `A, B, C, D, E, et al.` beyond five.

Files are named `<title>.pdf`, with `:` written as ` -`.

### Safety rules

- If the CrossRef lookup fails (timeout, rate limit), the file is left alone rather than filled with guesses.
- A title guessed from the page never renames a file that already has a readable name.
- A file is never renamed to a cut-off version of its current name.
- A stored title is never cleared.

### CrossRef

Answers are cached in `~/Library/Caches/pdfmeta/crossref`, so a preview and the run after it see the same data; delete the folder to refetch. Lookups run one at a time, at about two seconds each on CrossRef's public pool. Set `CROSSREF_MAILTO=you@example.com` to use their faster "polite" pool.

### Known limits

- CrossRef's own mistakes pass through, such as authors registered surname-first.
- A keyword list that wraps mid-phrase can lose its last words.
- PDFs whose text layer has no word spacing yield run-together keywords.

## Python: `pdf-metadata-tool`

```sh
uv sync
uv run pdf-metadata-tool process-all <path> --dry-run
uv run pdf-metadata-tool process-all <path>
```

Commands: `extract`, `rename`, `fix-metadata`, `process-all`. Writing keywords in the form Preview recognises needs `exiftool` on the PATH. Backups go to a `backups/` folder beside the PDFs.
