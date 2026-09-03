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
6. **Notarizes** it (`xcrun notarytool submit --wait`), staples the ticket onto
   the bundle, and re-zips. `SKIP_NOTARIZE=1` skips this.
7. **Prints** the git commit/tag/push and `gh release create` commands for you to
   run manually. Nothing is committed, tagged, pushed, or published.

Pass `--publish` only when you want the script to run those steps for you.

## Notarize without cutting a release

```sh
scripts/notarize.sh              # build Release, notarize, staple, zip
scripts/notarize.sh --install    # ... and replace /Applications/Notable.app
scripts/notarize.sh path/to/Notable.app   # notarize an app that already exists
```

No version bump, no tag, no clean-tree requirement, nothing published. Use it for
a Gatekeeper-clean build to hand to another Mac. `release.sh` does the same
notarization inside the release ceremony — the two must not drift apart.

There is also a project-independent `~/.local/bin/notarize` for any other signed
artifact (`.app`, `.dmg`, `.pkg`, `.zip`); its default profile is remembered in
`~/.config/notarize/profile`.

## Send someone a DMG

```sh
scripts/make-dmg.sh              # build, package as a drag-to-Applications DMG,
                                 # sign the DMG, notarize it, staple it
scripts/make-dmg.sh 1.0.1        # override the version in the volume/file name
SKIP_BUILD=1 scripts/make-dmg.sh # reuse the previous build
SKIP_NOTARIZE=1 ...              # signed but NOT notarized (Gatekeeper still blocks)
```

It picks the best identity in the keychain by itself and says which of the three
outcomes you got: notarized (recipient double-clicks and it opens), Developer ID
but un-notarized, or merely `Apple Development` signed (rejected on any other
Mac). Like the other scripts it checks the notary credentials *before* building
and builds to `$TMPDIR` — but to a **stable** path rather than a `mktemp -d`,
because `SKIP_BUILD=1` has to find the previous build. The finished DMG lands in
`build/` next to the release zips.

## Notarization credentials

One-time, per machine — the credentials belong to the **Apple ID + team**, not to
an app, so the same profile notarizes anything signed by this team:

1. Create an app-specific password at `appleid.apple.com` → Sign-In and Security.
2. Store it (it prompts for the password, so it stays out of the shell history):

```sh
xcrun notarytool store-credentials "<profile-name>" \
  --apple-id <apple-id> --team-id KHP87QK87Q
```

**The profile name lives in one file**, `~/.config/notarize/profile`; every script
(`release.sh`, `notarize.sh`, `make-dmg.sh`, `~/.local/bin/notarize`) reads it and
`$NOTARY_PROFILE` overrides it. Since the credentials belong to the Apple ID and
not to Notable, the name should stay project-neutral.

There is **no way to rename or delete a profile**: `notarytool` offers only
`store-credentials`, and it writes into the data-protection keychain, which
`security` cannot enumerate, let alone edit. Renaming therefore means storing the
credentials again under the new name and repointing that file; the old profile
stays behind, unreachable and harmless. It needs the app-specific password again
— Apple shows that only once at creation, so if it was not kept, generate a new
one (free, and the old one can be revoked at `appleid.apple.com`).

Three conditions decide whether Apple accepts a submission, all satisfied by the
Release build: a **Developer ID Application** signature, **hardened runtime**, and
a **secure timestamp**. The scripts check all three *before* uploading, because
the notary service reports them only after the upload and the queue wait.

**Check the identity on the `Authority=` line of `codesign -d --verbose=2`, never
by grepping the designated requirement.** The DR encodes the certificate kind as
OIDs (`field.1.2.840.113635.100.6.1.13`) and never contains the string
`Developer ID Application` — a check written that way rejects every valid app.
That bug sat in `release.sh` from the day notarization was added until 2026-09-03,
which is why the account had no submission history at all.

## What notarization does and does not expose

Apple receives the built `.app` and nothing else — no notes, no recordings, no
database; those live in `~/Library` and the user's notes folder and are never in
the bundle. The submission is private to the Apple ID and appears in no public
list (`xcrun notarytool history` needs your credentials to read it). The one
thing that becomes readable to anyone holding the binary is the signing identity
name, `Developer ID Application: Jonas Gehring (KHP87QK87Q)` — that follows from
Developer ID signing itself, not from notarizing, and is unavoidable short of
enrolling as an organization. Publishing is a separate, explicit step:
`release.sh --publish`.

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
