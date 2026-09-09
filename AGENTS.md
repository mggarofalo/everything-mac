# Repository guide

EverythingMac is a native macOS filename-search application written in Swift 6. It supports macOS 14 and newer.

## Source map

- `Package.swift` defines the reusable `IndexCore` package.
- `Sources/IndexCore/` contains scanning, storage, parsing, search, sorting, cache, and FSEvents logic.
- `Tests/IndexCoreTests/` contains the core behavior and regression tests.
- `App/project.yml` is the source of truth for the Xcode project and all 3 executable targets.
- `App/Sources/` contains the SwiftUI and AppKit interface.
- `App/ServiceSources/Indexing/` contains the persistent indexing service entry point.
- `App/ServiceSources/Search/` contains the UI-facing search service entry point.
- `App/Shared/` contains XPC messages, trust validation, and application-removal handling.
- `App/LaunchAgents/` contains the `SMAppService` launch-agent property lists.
- `scripts/` contains local installation and DMG release workflows.

## Run the right checks

Run core tests from the repository root:

```bash
swift test
```

Run the complete quality gate before committing production Swift changes. It
enforces a cyclomatic-complexity maximum of 10 and 95% core line coverage:

```bash
./scripts/check-quality.sh
```

Generate and compile the complete application after changing UI, service, signing, or project configuration code:

```bash
xcodegen generate --spec App/project.yml --project App
xcodebuild -project App/EverythingMac.xcodeproj \
  -scheme EverythingMac \
  -configuration Release \
  CODE_SIGNING_ALLOWED=NO \
  build
```

`App/EverythingMac.xcodeproj` is generated and ignored. Edit `App/project.yml`, never the generated project.

Use `./scripts/build-dev.sh` only when an installed test is needed. It signs the app, replaces `/Applications/EverythingMac.app`, and restarts registered services. Do not install or restart services for a compile-only check.

Use `./scripts/build-dmg.sh --preview` to test packaging. Public release builds require the `--release` flow, a Developer ID Application identity, and notarization credentials.

Test whole-index performance in Release. Debug search timings do not represent the product and can be about 100 times slower in the matching loop.

## Preserve process boundaries

The request path is:

```text
EverythingMac.app → EverythingMacSearchService → EverythingMacIndexingService
```

Only the indexer receives Full Disk Access. Keep filesystem scanning, cache access, index mutation, and query execution there. The UI owns presentation and user-confirmed file actions. The search service remains a narrow forwarding boundary.

Both XPC listeners validate code signatures in `App/Shared/ConnectionTrust.swift`. The indexer and app intentionally use `com.everythingmac.app` as their signing identifier. The search service uses `EverythingMacSearchService`. If an identifier changes, update `ConnectionTrust`, `App/project.yml`, both build scripts, and the relevant tests or verification together.

The services are user launch agents registered through `SMAppService`. Quitting the UI must not stop indexing. Removing the application bundle must unregister both agents and remove generated data. An in-place application upgrade must preserve them. Keep both cases working when changing `ApplicationBundleMonitor` or installation scripts.

`BackgroundServices.registrationRevision` reloads stored launch-agent definitions after an embedded plist or executable-path change. Bump it whenever an existing registration must be replaced. Refresh both services together because the search service retains its connection to the indexing service.

## Preserve index correctness

`IndexActor` serializes mutable index state. Whole-disk scans and large derived-index builds may run outside the actor, but publish completed state atomically. Do not expose partially built stores to searches.

Persist only the highest FSEvents identifier whose changes have been applied. Replay events that arrive during a scan. Rebuild when FSEvents reports dropped history or when mounted local volumes change.

The cache format, exclusion-rule fingerprint, and canonical path rules are compatibility boundaries. Increment the cache magic when its binary layout changes. A cache created under different exclusion rules must rebuild.

The application-support directory must remain owner-only mode `0700`; cache files must remain mode `0600`. The cache contains filenames and paths gathered with Full Disk Access.

Network volumes stay excluded. Avoid filesystem calls against an unclassified mount because an unavailable share can block the indexer.

Keep tombstones out of durable cache writes and compact them when their ratio crosses the established threshold. Preserve stable paths and record identifiers across incremental updates where the existing APIs promise them.

## Preserve query behavior

Plain terms, colon filters, Boolean operators, and regular expressions share one query plan. Update parser, planner, suggestions, validation messages, README examples, and tests together when changing syntax.

New keystrokes must cancel obsolete searches before expensive actor work. Broad regular expressions and other full scans must remain cancellable.

Match Path includes ancestor components without requiring millions of reconstructed full-path strings. Measure memory and latency before replacing compact postings or parallel metadata arrays with more convenient structures.

## Handle files safely

Moving a result to the Trash requires confirmation and a second device-and-inode check. Preserve that time-of-check protection when changing selection or result actions.

Treat the worktree as user-owned. Keep unrelated edits intact. Do not delete caches, replace the installed app, stop services, or perform release operations unless the task requires that state change.

Update `README.md` for user-visible behavior, `SECURITY.md` for security-boundary changes, and `CHANGELOG.md` for release-facing changes.
