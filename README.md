# EverythingMac

EverythingMac is a local file-name search app for macOS. It maintains an index of files and folders, then returns literal matches as you type.

![A grouped Boolean search for applications](assets/search-boolean.png)

The app searches local mounted volumes, stays current through FSEvents, and keeps working in the background after you close the search window. It does not rank results or search file contents.

EverythingMac supports macOS 14 Sonoma and newer.

## Install EverythingMac

Open the release DMG and drag `EverythingMac.app` into Applications. Launch the app from Applications so its background services have a stable path.

The indexing service needs Full Disk Access. The UI and search service do not. Add this executable in `System Settings > Privacy & Security > Full Disk Access`:

```text
/Applications/EverythingMac.app/Contents/MacOS/EverythingMacIndexingService
```

EverythingMac shows a loading panel while the services start. The status bar reports progress once the first scan begins. Later launches load the saved index and replay filesystem changes.

## Search for files

Enter any part of a file or folder name. Use the sliders button beside the search field to enable `Match Path`, `Match Case`, or `Match Whole Word`.

You can sort the result table by name, path, size, kind, or modification date. Double-click a result to open it. The shortcut menu can open it with another app, reveal it in Finder, copy its name or path, or move it to the Trash. Use `File > Export Results` to save the current rows as a tab-separated file.

### Filter results

Filters can appear anywhere in a query:

| Filter | Example | Result |
| --- | --- | --- |
| `in:` | `in:~/Downloads` | Items in a folder or its descendants |
| `filetype:` | `filetype:md` | Files with one of the listed extensions |
| `type:` | `type:folder` | Files or folders only |
| `size:` | `size:1mb..10mb` | Items within a size comparison or range |
| `modified:` | `modified:7d` | Items from a date or relative period |
| `path:` | `path:Sources` | Text matched against the full path |
| `name:` | `name:Package` | Text matched against the filename |
| `regex:` or `rx:` | `rx:handoff\.md$` | Names matched by a regular expression |
| `limit:` | `limit:100` | A maximum number of returned rows |

Separate terms with spaces to require all of them. Use uppercase `AND`, `OR`, `XOR`, and `NOT` for explicit Boolean expressions. Parentheses control grouping.

```text
report in:~/Documents filetype:pdf
in:~/Desktop OR in:~/Downloads
(marvel in:~/Desktop) OR (codex in:~/Downloads type:folder)
package in:~/Source NOT path:node_modules
filetype:md modified:7d size:<1mb
```

Quote values that contain spaces, such as `in:"~/Project Files"`. The editor suggests filters and operators as you type and explains invalid expressions below the field.

Regular expressions match names by default. Enable `Match Path` to apply them to full paths.

![Extension, size, and result-limit filters applied to system fonts](assets/search-filters.png)

## Manage the index

Use `File > Rebuild Index` or `Settings > General > Rebuild Index Now` to scan from scratch. A forced rebuild clears the visible results before scanning begins.

The Exclude and Volumes settings control which local paths enter the index. Applying either set of changes rebuilds the cache with the new rules. EverythingMac excludes common version-control, dependency, build, and cache directories by default.

Network volumes are not indexed. A slow or unavailable share must not block local search.

## Remove EverythingMac

Move `EverythingMac.app` out of Applications or into the Trash. Its removal observer stops and unregisters the indexing and search services. It also deletes the generated index.

## Build from source

Development requires macOS 14 or newer, Xcode 16 or newer, XcodeGen, SwiftLint,
and an Apple Development signing identity.

```bash
brew install xcodegen swiftlint
git clone https://github.com/mggarofalo/everything-mac.git
cd everything-mac
./scripts/build-dev.sh
```

The build script generates the Xcode project, makes a signed Release build, verifies it, and installs it in Applications. It also restarts registered services after an upgrade.

Set `LOCAL_SIGN_IDENTITY` to choose a certificate instead of using the first Apple Development identity:

```bash
LOCAL_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" \
  ./scripts/build-dev.sh
```

Use Release builds for app testing. Whole-index searches are intentionally optimized and are much slower in Debug builds.

Run the core test suite with:

```bash
swift test
```

Run the enforced complexity and coverage audit with:

```bash
./scripts/check-quality.sh
```

The quality gate runs the core and indexing-service boundary suites, caps
cyclomatic complexity at 10, requires 95% aggregate core line coverage, and
requires at least 85% line coverage in every core source file.

## Package a release

A preview DMG exercises the complete packaging flow with an Apple Development certificate. It is not notarized and is only suitable for local testing.

```bash
./scripts/build-dmg.sh --preview
```

A public build requires a Developer ID Application certificate and a `notarytool` keychain profile:

```bash
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
  ./scripts/build-dmg.sh --release
```

Set `NOTARY_PROFILE` if the profile is not named `notary`. The script signs the services and app, creates the DMG, notarizes and staples it, checks it with Gatekeeper, and writes a SHA-256 checksum under `dist/`.

## Understand the components

EverythingMac has 3 executable components:

| Component | Role |
| --- | --- |
| `EverythingMac.app` | Displays the interface and performs user-requested file actions |
| `EverythingMacSearchService` | Provides the UI-facing XPC endpoint |
| `EverythingMacIndexingService` | Scans metadata, owns the index, processes queries, and watches filesystem changes |

The `IndexCore` Swift package contains the storage, parser, search, sorting, scanning, and FSEvents code shared by the executables.

See [SECURITY.md](SECURITY.md) for the permission model, local-data protections, process trust checks, and disclosure process.

## License

EverythingMac is available under the [MIT License](LICENSE).

Its direct, literal search model is inspired by [Everything for Windows](https://www.voidtools.com/).
