# Local hardening review

This fork was reviewed and rebuilt from upstream commit
`bb178c419f518f7a32dc7b70bebb4677464ecd93` on September 8, 2026.

## Verdict

The upstream source is small, readable Swift and contains no analytics, network
client, updater, privileged helper, or shell-command execution. Its main security
cost is inherent to the product: useful whole-disk search requires Full Disk
Access, and the filename index is sensitive local data.

The upstream build was not a go for installation as-is. This branch is a go for a
personal local install after the changes below, provided the user accepts granting
Full Disk Access to a locally signed application.

## Changes made

- Sign Release builds with the local Apple Development identity, enable hardened
  runtime, reject debug entitlements, and verify the signature before installation.
- Replace the installed bundle completely instead of merging files into an old app.
- Store the index in a mode-0700 directory and the cache itself with mode 0600.
- Remove tombstoned filenames before every durable cache write.
- Wait for Full Disk Access before scanning, disable rebuild actions without it,
  and discard the cache if access is revoked so a partial index is never trusted.
- Preserve FSEvents delivery order, persist only fully processed checkpoints, replay
  changes made during rebuilds, and retry transient monitor-start failures.
- Treat `MustScanSubDirs`, dropped history, mount changes, metadata changes, and
  file/directory replacements according to their FSEvents semantics.
- Fix exclusion-prefix component boundaries, including exclusion of `/`.
- Keep table selection attached to a live pathname, clear stale selections, confirm
  Trash operations, and verify device/inode identity again after confirmation.
- Remove an unsafe concurrent mutation in the parallel query engine.
- Separate the indexer, search endpoint, and UI into distinct processes. The two
  agents start through `SMAppService` and survive when the UI quits.
- Restrict both XPC endpoints to the expected executables signed by the same team.
- Build a derived component-substring index without duplicating full path strings,
  and cancel obsolete XPC searches from newer keystrokes.

## Verification

- `swift test`: twelve tests pass, including live FSEvents delivery, indexed Match
  Path semantics, incremental additions/deletions, slash-command parsing, filetype
  and regex semantics, command-query index routing, and search cancellation.
- Xcode Release build: succeeds with Swift 6.
- Installed bundle: `codesign --verify --deep --strict` succeeds.
- Signature: Team ID `649367BDD4`, hardened-runtime flag present, no
  `com.apple.security.get-task-allow` entitlement.
- Permission gate: on a machine without an existing grant, the app shows the Full
  Disk Access banner, reports zero indexed objects, and disables Rebuild Index.
- Full-disk run: indexed 3,634,378 objects in about 30 seconds and wrote a 200 MB
  mode-0600 cache. Resident memory settled around 350–420 MB after the scan.
- Search/live update: a unique filename query returned its one result immediately.
  A new Desktop probe appeared on the next query; its FileProvider-backed deletion
  took about 23 seconds to reconcile.
- Service lifecycle: the UI quit in about 200 ms while both launch agents remained
  active. A file created with no UI running appeared when the UI reopened.
- Search latency: a standalone optimized benchmark against the real cache ran
  `desktop marvel present` in 89 ms (one result) and `HARDENING.md` in 0.4 ms.
  Realistic character-by-character entry fell from 9.4 seconds after the last
  keystroke to about 0.4 seconds, including accessibility-tool overhead.
- Derived-index cost: 76.3 million posting IDs occupy 96.0 MB after delta/varint
  encoding rather than 305 MB as raw `UInt32` values. The optimized two-pass build
  took 3.6 seconds versus 3.3 seconds before compression. A standalone steady-state
  measurement was 177 MB total versus a 77 MB store-only baseline, making the
  derived index's measured cost about 100 MB rather than roughly 330 MB. Peak RSS
  fell from 836 MB to 681 MB; peak physical footprint fell from 812 MB to 502 MB.
  The installed indexer measured 174 MB RSS immediately after rebuilding and 218 MB
  after the live search smoke test, down from the prior implementation's roughly
  610 MB initial steady-state measurement.
- Extended search: `/filetype md` returned 50,444 records in 7 ms. Indexed regexes
  `handoff\.md$` and `.*handoff\.md$` returned 43 records in 0.2–1.8 ms. A broad
  filename regex with no mandatory literal took 0.9 seconds; the corresponding
  worst-case full-path scan took 8.0 seconds. Those fallbacks run in parallel and
  remain cancellable by newer input. The initial 0.6.0 service accidentally routed
  slash commands around that derived index, producing observed delays of 6–30
  seconds despite the fast core benchmark. After fixing the routing, installed-app
  smoke tests for `/filetype md`, `/regex handoff\.md$`, and `handoff` all rendered
  updated results within the first 250 ms observation window.

## Installation experience

XcodeGen creates the project. Xcode builds one UI and 2 background agents. The
script checks their signatures, swaps the complete bundle into `/Applications`,
and restarts registered agents. macOS required one extra authorization step for
the new indexer executable. After that grant, the existing cache loaded without a
rescan. In normal use, filename queries and FSEvents changes were immediate.

## Remaining limitations

- The compact filename cache is durable, but the derived trigram postings are
  rebuilt after the indexing agent restarts. On the measured 3.6-million-record
  index this took 3.5–8 seconds; searches submitted during that window wait for it.
- FileProvider-backed Desktop deletions can arrive well after creations; the measured
  deletion remained searchable for about 23 seconds before reconciliation.
- Unlike Everything on NTFS, this app has no APFS catalog/journal API that provides
  an instant authoritative filename list. Its first index is a filesystem crawl;
  FSEvents maintains that snapshot afterward.
- Full Disk Access is broad. A future malicious update signed under the same identity
  would inherit the app's ability to read protected files. Review changes before
  rebuilding and installing them.
- The application is locally signed and not notarized for distribution. That is
  appropriate for this personal build, not for publishing binaries to other users.
- Network volumes are deliberately excluded because walking a stalled share can hang
  the scan. Local mounted volumes are included.
