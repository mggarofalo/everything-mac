---
name: everythingmac-release
description: Release EverythingMac by updating its version, validating it, publishing a signed and notarized DMG with a matching Git tag and GitHub release, and optionally reinstalling it locally. Use for EverythingMac release, tag, publication, or post-release installation requests; not for ordinary development builds.
---

# Release EverythingMac

Treat a public release and a local installation as separate artifacts: public
DMGs require Developer ID signing and notarization, while `build-dev.sh` uses a
stable Apple Development identity for local testing.

## Prepare

1. Confirm the requested semantic version does not already exist locally or on
   the remote and that the worktree contains no unrelated changes that would be
   swept into the release.
2. Update both `MARKETING_VERSION` values in `App/project.yml` and increment both
   matching `CURRENT_PROJECT_VERSION` values. Keep the app and indexing service
   versions identical.
3. Rename the top `Unreleased` changelog section to the release version. Update
   user or security documentation when the underlying change requires it.

## Validate and package

Run `./scripts/check-quality.sh`, then the compile-only app build from
`AGENTS.md`. Fix failures before publishing.

Build the public artifact with `./scripts/build-dmg.sh --release`. This requires
a `Developer ID Application` identity, timestamping, a working notarytool
keychain profile, stapling, Gatekeeper assessment, and the generated SHA-256
file. Never publish a preview, ad-hoc, or Apple Development-signed DMG. If public
signing or notarization is unavailable, stop before pushing, tagging, or creating
a partial GitHub release and report the missing prerequisite.

## Publish

Commit only the intended release changes. Follow repository branch protection:
prefer a release branch and pull request when direct pushes to the default branch
are not the established path. Wait for required CI and merge before tagging.

Create an annotated `v<version>` tag at the merged release commit and push that
exact tag. Create the GitHub release from it, attach the notarized DMG and its
SHA-256 file, and use the matching changelog section for concise release notes.
Verify the remote tag, GitHub release, assets, and checksum before declaring the
release complete.

## Install locally

Only when the user explicitly requests an installed test, run
`./scripts/build-dev.sh`. It replaces `/Applications/EverythingMac.app` and
restarts registered services without deleting the index cache. Verify the
installed bundle version, signatures, and both `launchctl` jobs. Do not use
`scripts/relaunch.sh` unless a cache-destructive rebuild was separately requested.
