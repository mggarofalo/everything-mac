# Security

EverythingMac indexes filenames and filesystem metadata across local volumes. This requires broad filesystem access, so the project separates indexing from the UI and keeps index data on the Mac.

## Report a vulnerability

Private vulnerability reporting is not enabled yet. Open a [security contact request](https://github.com/mggarofalo/everything-mac/issues/new) so the maintainer can provide a private channel. Do not include exploit details or sensitive local paths in the issue.

Security fixes target the latest release and the current `main` branch. Older builds may not receive separate patches.

## Data stays local

EverythingMac does not send the index, searches, usage data, or diagnostics to a server. It has no analytics client, updater, or application-owned network service.

The Help menu can ask macOS to open this project’s GitHub pages in the default browser. Opening a result can also launch another application chosen by the user. Those applications have their own security and privacy behavior.

The index contains this metadata:

- File and folder names
- Full paths
- File sizes
- Modification dates
- File and folder flags used by search

EverythingMac does not index file contents. Full Disk Access still gives the indexing process the technical ability to read protected files, so only install builds you trust.

## Full Disk Access belongs to the indexer

Only `EverythingMacIndexer` needs Full Disk Access. The main app and `EverythingMacSearchService` do not request it.

The indexer checks access before loading or building the index. macOS enforces access to protected paths. Revoking Full Disk Access stops future protected filesystem reads, but it does not erase metadata already stored in the cache. Remove the app to run automatic cleanup, or delete the cache manually.

## The cache is private to the user account

EverythingMac stores its cache at:

```text
~/Library/Application Support/Everything-Mac/index.idx
```

The application-support directory uses POSIX mode `0700`. The cache uses mode `0600`. These permissions prevent other local user accounts from reading the index through normal filesystem access.

The cache is not encrypted. Processes running as the same user, software with equivalent filesystem access, and administrators may still read it. FileVault is the appropriate control for data at rest when the Mac is shut down.

Cache writes use a staging file and replacement. The cache records the active exclusion-rule fingerprint and its processed FSEvents checkpoint. EverythingMac rebuilds data with an incompatible format or rule set instead of trusting it.

Moving the application bundle out of Applications triggers a separate removal observer. The observer unregisters both background services and deletes the application-support directory. It distinguishes removal from an in-place upgrade so an update does not destroy the index.

## XPC connections verify signed peers

The UI does not connect directly to the privileged indexer. Requests follow this path:

```text
EverythingMac.app → EverythingMacSearchService → EverythingMacIndexer
```

Each XPC listener validates the connecting process with Security.framework. It requires the expected executable identifier and the same signing team as the receiving process. A process running under the same user account is not accepted on that fact alone.

The search service accepts `com.everythingmac.app`. The indexer accepts `EverythingMacSearchService`. Changes to these signing identifiers must update the trust policy and packaging checks together.

## File actions require current identity

EverythingMac asks for confirmation before moving a result to the Trash. It records the selected item’s device and inode, then checks them again after confirmation. If the path now refers to another item, the operation stops.

Open, Open With, and Reveal in Finder use macOS workspace APIs. Export writes the current result metadata only to a location selected by the user.

## Builds fail closed

Development and release scripts verify the app and embedded services before installation or distribution.

Local builds require an Apple Development identity. The install script requires hardened runtime, rejects the debug `get-task-allow` entitlement, checks service identifiers, stages a complete replacement bundle, and restores the previous bundle if verification fails.

Public releases require a Developer ID Application identity. The release script signs components from the inside out, submits the DMG to Apple for notarization, staples the result, runs Gatekeeper assessment, and writes a SHA-256 checksum. Any failed step stops the release.

Preview DMGs use development signing and skip notarization. They are not public release artifacts.

## Current limitations

EverythingMac uses hardened runtime but is not sandboxed. Sandboxing would conflict with whole-volume indexing under the current design.

Full Disk Access is a broad grant. A malicious replacement accepted by macOS under the same signing requirement could abuse that access. Protect the signing identity, review updates, and distribute only notarized release builds.

The index reflects FSEvents delivery after its initial scan. FileProvider-backed paths can report deletions late, and a result may briefly refer to an item that no longer exists. Destructive actions therefore revalidate item identity.

EverythingMac indexes local volumes only. Network volumes are excluded to avoid blocking the indexing process on an unavailable share.
