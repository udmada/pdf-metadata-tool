# pdf-metadata-tool

Fixes the metadata of academic PDFs so they show up properly in Books and Preview, and renames the files after their titles.

The tool has been rewritten from Python to Swift. The Swift version (`pdfmeta`) is the one to use; the original Python version is kept for reference.

## Swift: `pdfmeta`

Requires macOS 14+ and Swift 6.

```sh
swift build -c release
swift run -c release pdfmeta extract paper.pdf               # show what would be used
swift run -c release pdfmeta process-all ~/Papers --dry-run  # preview changes
swift run -c release pdfmeta process-all ~/Papers            # apply them
swift test
```

Options:

- `-r`, `--recursive`: descend into subfolders (folders named `backups` are skipped)
- `--no-doi-lookup`: work offline, without asking CrossRef
- `extract --json`: machine-readable output
- `process-all --dry-run`: preview only
- `process-all --no-backup`: do not keep a copy of each rewritten PDF

Running `process-all` twice changes nothing the second time.

### Fixing a paper by hand

Books, theses, reports and preprints often have no DOI that CrossRef knows, so the tool can only keep what is stored or guess. Set those yourself:

```sh
swift run -c release pdfmeta set "An In-Depth Analysis.pdf" \
  --title "Hatescape: An In-Depth Analysis of Extremism and Hate Speech on TikTok" \
  --author "Ciarán O’Connor" --subject "Institute for Strategic Dialogue"
```

Only the fields you pass change; pass an empty value (`--author ""`) to clear one. A new title also renames the file. `--keywords`, `--dry-run` and `--no-backup` work as elsewhere. Later `process-all` runs leave hand-set values alone.

### What applying does

For each PDF whose title, author, subject or keywords would change:

1. The original is copied to `backups/<name>.backup.pdf` beside it (unless `--no-backup`).
2. PDFKit rewrites the file to a staging location with the new fields.
3. The staged copy is reopened and checked: same page count, fields read back as written.
4. If the PDF carries an XMP metadata block, its title, creator, description, subject and keywords are set to match, and the copy is checked again. PDFKit leaves XMP untouched, so this is done by appending a standard PDF incremental update; no exiftool is involved.
5. Only then does it replace the original.

The file is then renamed if its name should change; a rename never overwrites another file. A rename on its own does not rewrite or back up the file. Encrypted PDFs are left alone.

Bookmarks, annotations, links and page text survive the rewrite. This was checked on 142 real papers, where file size stayed within a few percent for all but one. On the same set, exiftool read back matching info and XMP values from every rewritten file, and poppler reported no new errors.

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
- Only a CrossRef-confirmed title renames a file that already has a readable name; stored and guessed titles rename machine-named files only.
- A file is never renamed to a cut-off version of its current name.
- A stored title is never cleared.

### CrossRef

Answers are cached in `~/Library/Caches/pdfmeta/crossref`, so a preview and the run after it see the same data; delete the folder to refetch. Lookups run one at a time, at about two seconds each on CrossRef's public pool. Set `CROSSREF_MAILTO=you@example.com` to use their faster "polite" pool.

### Known limits

- CrossRef's own mistakes pass through, such as authors registered surname-first.
- A keyword list that wraps mid-phrase can lose its last words.
- PDFs whose text layer has no word spacing yield run-together keywords.
- macOS only. PDF reading and writing go through PDFKit, which has no Linux or Windows version; other platforms would need a different PDF library.
- An embedded XMP block that is compressed with anything other than Deflate, or sits in a PDF structure the tool does not recognise, is left with its old values; the run reports how many.
- A title guessed from the page can be wrong, typically on books and reports. Review the `[content]` lines in a dry run.

### Prebuilt binary

Every push builds and tests the tool natively on Apple silicon (`macos-26`) and Intel (`macos-15-intel`) runners, then joins the two into a universal binary. Each run has three artifacts: `pdfmeta-macos-arm64`, `pdfmeta-macos-x86_64` and `pdfmeta-macos-universal`. Tags named `v*` also publish all three as a release:

```sh
git tag v0.1.0 && git push origin v0.1.0
```

The workflows are written in [Pkl](https://pkl-lang.org) under `.github/pkl/`. After changing them, regenerate the YAML with `mise run pkl:gen` and commit both.

## Python: `pdf-metadata-tool` (legacy)

```sh
uv sync
uv run pdf-metadata-tool process-all <path> --dry-run
uv run pdf-metadata-tool process-all <path>
```

Commands: `extract`, `rename`, `fix-metadata`, `process-all`. Writing keywords in the form Preview recognises needs `exiftool` on the PATH. Backups go to a `backups/` folder beside the PDFs.
