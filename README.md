# EverythingMac

Type part of a filename and every file and folder that matches shows up instantly, across every mounted volume. It's a macOS clone of [Everything](https://www.voidtools.com/), the search tool I lived in back on Windows.

![EverythingMac searching across 8.2 million files](assets/screenshot.png)

This fork currently supports local source builds on macOS 14 or newer.

> The folder is called `everything-rust` for historical reasons. There's no Rust in it. The whole app is Swift (SwiftUI and AppKit).

## Why I built it

I switched to Mac from Windows, and the one tool I missed right away was Everything by voidtools. Hit a shortcut, type a few letters, and it lists every matching file and folder on the whole disk before you finish typing. It doesn't make you wait while it builds an index, and it doesn't reshuffle the results to show you what it thinks you meant.

Spotlight is supposed to cover this. It doesn't, at least not for me. The part that broke it was folder search: I'd look for a folder I knew was there and Spotlight wouldn't list all the ones that matched. It buries results and second-guesses what I actually typed. I'm a programmer. Finding a file by name is the most basic thing a computer does, and I don't want to fight it to do that.

So I wrote my own. It reads every filename on the machine into memory and searches that as you type. Open it, type, it's there. Want to open the file? Right-click and pick whatever app you want.

## What it does

- Searches every mounted volume, updating on each keystroke.
- Indexes the whole disk, files and folders, and keeps the index current through FSEvents.
- Standard results table with Name, Path, Size, Kind, and Date Modified. Click a header to sort.
- Shows the real file-type icon and a readable kind for each row.
- Right-click menu: Open, Open With (lists every app associated with the file, plus a "Choose Application…" option to open it with anything), Reveal in Finder, Copy Path, Copy Name, Move to Trash.
- Handles millions of files through compact substring postings, with a parallel full-scan fallback for short or wildcard queries.
- Runs as 3 processes: a persistent indexer, a persistent search endpoint, and a disposable UI. Quitting the UI does not stop indexing.

## Requirements

- macOS 14 (Sonoma) or newer
- Xcode 16 or newer (Swift 6)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build and run

```bash
git clone https://github.com/mggarofalo/everything-mac.git
cd everything-mac
./scripts/build-dev.sh
```

The script generates the Xcode project, builds a hardened Release binary, verifies its signature and entitlements, and copies the app into `/Applications`. Build Release, not Debug. The search loop runs about 100 times slower without optimization.

### Signing it as yourself

The build script selects the first Apple Development identity in your login keychain. Set `LOCAL_SIGN_IDENTITY` when you want another identity:

```bash
LOCAL_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./scripts/build-dev.sh
```

### Full Disk Access

The indexing agent needs its own one-time Full Disk Access grant. Open System
Settings > Privacy & Security > Full Disk Access, press `+`, then press
Command-Shift-G in the file picker and enter:

```text
/Applications/EverythingMac.app/Contents/MacOS/EverythingMacIndexer
```

The UI does not need Full Disk Access. The search service only receives filename
query requests and results from the indexer.

The first launch scans the whole disk and writes the index to a cache, so it takes a few minutes depending on how many files you have. After that it starts instantly and picks up file changes as they happen.

## Using it

Launch it and start typing. Matches show up right away. Click a column header to sort. Double-click a row to open it, or right-click for Open With, Reveal in Finder, Copy Path, Move to Trash, and the rest.

The sliders button at the right of the search field contains Match Path, Match Case,
and Match Whole Word options. The options are remembered between launches.

Filename text and metadata filters form Boolean expressions. Spaces imply `AND`;
uppercase `AND`, `OR`, `XOR`, and `NOT` are operators. Parentheses control grouping.
Operators appear as pills in the editor, while lowercase words such as `or` remain
ordinary filename text.

- `in:~/Downloads` matches that folder and its descendants. Quote values containing
  spaces, for example `in:"~/Project Files"`.
- `filetype:md` finds Markdown files; `filetype:doc,docx` accepts either extension.
- `type:file` and `type:folder` restrict the result kind.
- `size:>100mb` and `size:1mb..10mb` filter by file size.
- `modified:today`, `modified:7d`, and `modified:2026-09-01..2026-09-08` filter by date.
- `path:Sources` always matches the full path; `name:Sources` always matches the name.
- `regex:handoff\.md$` matches names ending in `handoff.md`; use `rx:` as a short alias.
- `limit:100` caps the returned rows after filtering and sorting.

Examples:

```text
marvel in:~/Desktop
in:~/Desktop OR in:~/Downloads
(marvel in:~/Desktop) OR (codex in:~/Downloads type:folder)
in:~/Desktop (rx OR codex OR release OR marvel OR filetype:md)
package in:~/Source NOT path:node_modules
```

Type part of a filter or operator to open contextual suggestions, then press Tab or
click a row to complete it. Invalid expressions are explained directly below the
field. Regex normally examines the filename; enable Match Path to examine the full
path. Quote regex values containing spaces or parentheses.

## How it works

- Every filename lives in one big UTF-8 buffer, with the metadata (size, dates, flags) held in parallel arrays alongside it. That whole structure gets written to a binary cache so restarts are fast.
- A derived trigram index maps filename and path-component substrings to delta/varint-encoded record-ID postings in one byte arena. Searches start from the rarest posting and verify only those candidate paths; short and wildcard queries retain the parallel full-scan fallback. The measured 76-million-entry derived index occupies about 100 MB at steady state.
- Boolean queries compile to an expression tree. `AND` starts with the cheapest
  indexed or directory candidate set and refines it; `OR` unions sorted IDs and
  `XOR` computes their symmetric difference.
- Newer keystroke queries cancel obsolete searches already executing in the indexer, so stale work cannot queue ahead of what is currently in the field.
- An FSEvents watcher folds new, renamed, deleted, and modified files back into the index.

The app checkpoints only events that it has processed. It replays changes made during scans and performs a complete rebuild when FSEvents reports lost history.

## Tests

```bash
swift test
```

## License

[MIT](LICENSE)
