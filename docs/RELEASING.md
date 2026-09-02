# Releasing Notable

Notable is a single-user macOS app: locally built, certificate-signed,
installed to `/Applications/Notable.app`. This doc covers the version + release
plumbing. (The signing rationale — why a stable identity is required — is in the
project spec `specs/release-and-signing.md`.)

## Version scheme

Two values live in `project.yml` under the `Notable` app target's `settings.base`
and are surfaced into the Info.plist:

- `MARKETING_VERSION` → `CFBundleShortVersionString` — user-facing semver
  (`X.Y.Z`). The **only** human-chosen value; it is the release-script argument.
- `CURRENT_PROJECT_VERSION` → `CFBundleVersion` — a monotonic build counter,
  derived automatically from `git rev-list --count HEAD`. Never hand-managed.

`scripts/release.sh` is the single writer of both, so the committed `project.yml`
always reflects the last released version.

## Why builds go to `$TMPDIR`

When the repo lives in a synced folder (iCloud Drive, Dropbox), the file
provider can move or evict files mid-build, which breaks `codesign`. Both
scripts build to a throwaway `derivedDataPath` under `$TMPDIR` and clean it up
on exit. Do not point `-derivedDataPath` at a path inside a synced repo.

## Install a local build

```sh
scripts/install.sh
```

Builds Release to an unsynced DD, replaces `/Applications/Notable.app`, and
strips `com.apple.quarantine`. TCC grants are keyed to that path, which is why we
always install there.

## Cut a release

```sh
scripts/release.sh 1.0.0            # build + verify + zip only (prints publish cmds)
scripts/release.sh 1.0.0 --publish  # also commit, tag, push, and `gh release create`
```

Without `--publish` the script:

1. Requires a clean working tree.
2. Bumps `MARKETING_VERSION` (= arg) and `CURRENT_PROJECT_VERSION` (= commit count).
3. `xcodegen generate` + Release build to an unsynced DD.
4. Verifies the signature is **certificate-based** — it aborts if the designated
   requirement (`codesign -d -r-`) contains `cdhash`, i.e. if the app is ad-hoc
   signed (which would reset every TCC grant on rebuild).
5. Zips the app with `ditto -c -k --keepParent` to `build/Notable-<version>.zip`.
6. **Prints** the git commit/tag/push and `gh release create` commands for you to
   run manually. Nothing is committed, tagged, pushed, or published.

Pass `--publish` only when you want the script to run those steps for you.

## One-time TCC re-grant

TCC (the macOS privacy DB) keys each permission grant to the app's bundle ID plus
its *designated requirement* (DR). Moving from ad-hoc to a stable certificate
identity changes the DR **once**, so the first cert-signed build you install will
re-prompt for all five permissions:

- Microphone
- Calendars
- System Audio Recording
- Accessibility (paste / synthesized ⌘V)
- Input Monitoring (the CGEventTaps in `HotkeyMonitor`)

Grant them once. From then on, every rebuild signed with the **same** certificate
produces a byte-identical DR, so TCC keeps recognizing the app and no further
re-prompts occur across rebuilds or version bumps.

If grants ever get into a bad state, reset and re-grant once:

```sh
tccutil reset All de.jonasgehring.notable
```
