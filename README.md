# Notable

**Local-first dictation and meeting transcription for macOS.** Hold a key, speak, let
go — polished text appears in whatever field you were typing in. Or let Notable sit in
on a call and hand you a diarized, summarized note afterwards.

<p align="center">
  <img src="docs/images/dictation.gif" width="640" alt="The dictation overlay: a small dark capsule showing a live waveform, then “Transkribiere…”">
</p>

**Your audio never leaves the device.** That is architecture, not a setting: recognition,
segmentation and diarization all run on the Neural Engine. The only thing that ever goes
out is text, and only at the points named below.

> Auf Deutsch: [README.de.md](README.de.md) · the app's interface is German.

## Dictation

Hold the hotkey, speak, release. A short tap switches to hands-free; the next tap ends it.
Measured warm: 5 s of audio → ~119 ms, 60 s → ~397 ms. Long dictations decode incrementally
while you speak, so releasing the key only leaves the tail to finish.

- **Parakeet TDT v3** (multilingual, default) or **Parakeet Unified** (English, true
  streaming); Whisper available as a comparison
- **Offline post-processing** — filler words, numbers and dates, a personal dictionary,
  paragraphs, and the structure you actually spoke ("new line", "bullet", "first…")
- **Snippets** — spoken shorthands expand to arbitrary, possibly multi-line text
- **Recording indicator** around the notch, as a pill under the menu bar, bottom-centre —
  or off

## Meetings

Microphone and system audio are captured on separate tracks (CoreAudio process tap),
speakers separated, matched to the calendar event, filed as a Markdown note.

- **Automatic call detection** for Zoom, Teams, FaceTime, Webex, Slack and browser calls —
  nothing is recorded until you confirm
- **Live notes** during the call in a floating WYSIWYG-Markdown window; they go into the
  note verbatim and inform the summary
- **Speaker naming** from the calendar attendees
- **Summary, chat with the transcript, and local full-text search**

## What leaves the device

| Data | Leaves the device |
|---|---|
| Audio | **never** |
| Meeting transcripts | for summarization, speaker naming and chat |
| Dictated text | **only when you ask** — a separate hotkey or a menu item |

The automatic pass after every dictation is offline and rule-based, and always will be.
The LLM improvement is a separate feature, off by default; while the switch is off, the
second hotkey is not even installed. Every run is counted, so it stays visible how often
dictated text has left the machine.

Providers are the Anthropic API (key in the Keychain) and the locally installed Claude
Code, Gemini and Codex CLIs. **For dictation, only the CLIs are permitted.** To be clear:
a CLI is *not* local — it is a locally started process that ships text to its vendor.

## Permissions

Notable asks for exactly what it needs, and explains each request in onboarding before
making it.

| Permission | What for |
|---|---|
| Microphone | dictation, and your own track in a meeting |
| System Audio Recording | the other side of the call (its own TCC right, not Screen Recording) |
| Calendar (read-only) | matching recordings to the right event |
| Accessibility + Input Monitoring | the global hotkey and pasting into the focused field |

## Requirements

macOS 14.4 or later, Apple Silicon. Process taps only — there is no ScreenCaptureKit
fallback. Speech models are downloaded on first launch and cached; a cold cache is carried
by Whisper Tiny until the real model has arrived, and the app says so while it is.

## Build and install

You need Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). The Xcode project is generated and not checked in.

```sh
xcodegen generate
scripts/install.sh          # build Release and install to /Applications
```

To sign, copy `Signing/Local.xcconfig.example` to `Signing/Local.xcconfig` and fill in
your Apple Team ID (the file is gitignored).

For a development run:

```sh
DD="$TMPDIR/notable"
xcodebuild -project Notable.xcodeproj -scheme Notable -configuration Debug \
  -derivedDataPath "$DD" build
open "$DD/Build/Products/Debug/Notable.app"
```

Tests need the app module in the same derived-data path, so build first:

```sh
xcodebuild -project Notable.xcodeproj -scheme Notable -configuration Debug \
  -derivedDataPath "$DD" test
```

Some tests download real models from HuggingFace on the first run (cached afterwards); the
full suite takes about nine minutes.

**Do not build into the repository folder if it is synced** (iCloud Drive, Dropbox): the
file provider decorates the build product with extended attributes, and `codesign` then
fails with `resource fork, Finder information, or similar detritus not allowed` — an error
that looks like anything except its own cause.

**Install to `/Applications`**, because macOS keys granted permissions to the bundle path
*and* to the signature. Changing the signing identity silently revokes all of them — the
checkbox in System Settings still looks ticked and nothing is logged. `project.yml` carries
the symptom and the remedy right next to the setting.

## Layout

- `Sources/Notable/Dictation/` — the latency-critical path: hotkeys, capture, ASR,
  post-processing, overlay, pasting
- `Sources/Notable/Meeting/` — system-audio tap, call detection, pipeline, live notes
- `Sources/Notable/Storage/` — SQLite (WAL) as the source of truth, Markdown as the
  projection, retention rules
- `Sources/Notable/Summarization/` — provider protocol, API and CLI providers
- `Sources/Notable/Stats/` — analysis of your own usage
- `specs/` — the design documents behind the features ([index](specs/README.md))
- `docs/RELEASING.md` — versioning, signing, notarization, delivery
- `CLAUDE.md` — working instructions for anyone (or anything) editing the code

## Scope

Notable is built for one person on their own machine. That is not modesty, it carries
decisions: built and signed locally instead of shipped through the App Store, no sandbox,
no multi-user plumbing, no sync. If you want to run it, expect to build it.

## License

MIT — see [LICENSE](LICENSE).
