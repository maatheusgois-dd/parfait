# Changelog

All notable changes to Nutola are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Releases are cut by merging `develop` into `main`. The version lives in
`VERSION` (single source of truth) and is stamped into `packaging/Info.plist`
by `make app`. To cut a release:

1. Bump `VERSION` (e.g. `0.0.2`) and add a dated `## [0.0.2]` section below
   that moves the `[Unreleased]` entries into the new version.
2. Commit on `develop`.
3. Merge `develop` → `main`.
4. Tag `main` as `v0.0.2` and push the tag: `git tag v0.0.2 && git push origin v0.0.2`.

## [Unreleased]

## [0.0.1] - 2026-07-20

Initial versioned release. Establishes the `VERSION` + `CHANGELOG.md`
release structure and ships the recording reliability and per-meeting
control improvements that accumulated on `develop`.

### Added
- Per-meeting transcription language picker — pin a call to one locale
  (English, Portuguese, Spanish, French, …) or leave on Auto for
  code-switching. Sticky for the whole call and across resumes.
  Lives in the live recording card and the live transcript header.
- Per-calendar-event template assignment — assign a template to a
  specific upcoming meeting so a one-off interview doesn't inherit the
  series' default template. Resolved after the smart/default template,
  so the override always wins.
- System-audio tap watchdog — polls the tap callback count and rebuilds
  the tap + aggregate if callbacks stall for 10s, so the far side of
  the call no longer goes silent mid-recording.
- Mic built-in fallback on restart — when a route change kills the mic
  engine and the Bluetooth headset mic is contended (Zoom/Chrome holding
  it), the engine now switches the system default input to the built-in
  mic and retries with a fresh AVAudioEngine, keeping the same open file.
- `VERSION` file (single source of truth) + `CHANGELOG.md`.
- Makefile stamps `VERSION` into `packaging/Info.plist` on every build.

### Fixed
- Headphone bleed no longer misattributes the local speaker's turns to
  "Others". Mic segments stay "me" and only drop as bleed echoes when
  their transcript text overlaps a concurrent "them" segment — talking
  over remote audio no longer disappears your side of the call.
- Mic engine restart after a default-input route change now rebuilds a
  fresh AVAudioEngine bound to the new device instead of reusing a stale
  one whose input format no longer matches the live route.
- Live transcript no longer auto-scrolls on every new segment — opens at
  the latest turn but lets you scroll up to read earlier turns without
  being yanked back down.
- Menu bar panel dismiss after opening Nutola or Settings.
- Archived calendar events UI + removed Gist publish from Share Notes.
- AI-generated template names sanitized (no `/` or `:`) and de-duplicated.
- Crash on launch from `MenuBarExtra(isInserted:)` toggle reverted.
