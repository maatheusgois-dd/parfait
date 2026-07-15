<p align="center">
  <img src="Resources/AppIcon-1024.png" style="border-radius: 20px" width="140" alt="Parfait icon — a layered parfait glass">
</p>

<h1 align="center">Parfait</h1>

<p align="center"><em>Layered meeting notes. Perfectly local.</em></p>

<p align="center">
An open-source, on-device meeting notetaker for macOS — a lightweight alternative to Granola.<br>
It lives in your menu bar, notices when a meeting starts, records both sides of the call,<br>
and writes a transcript with named speakers plus templated notes — without audio ever leaving your Mac.<br>
Then it hands any meeting to <strong>your assistant</strong> — Apple Intelligence, Claude, or Codex — through a
built-in MCP server: one call, your whole history, or the meeting happening <em>right now</em>, with nothing uploaded.
</p>

<p align="center">
<sub>📦 <strong>A signed <code>.app</code> download is coming soon.</strong> Until then, <code>make install</code>
(below) builds it in about two minutes — the way to try it today.</sub>
</p>

---

## What it does

- **Auto-detects meetings.** When Zoom, Meet, Teams, FaceTime — anything — starts using your
  microphone, Parfait offers to record (or just starts, if you tell it to). Manual recording is
  one click in the menu bar.
- **Records both sides.** Your mic through AVAudioEngine; everyone else through a Core Audio
  process tap on system audio. No virtual audio drivers, no kernel extensions, no bots joining
  your calls.
- **Transcribes on device** with Apple's SpeechAnalyzer (the macOS 26 speech engine) — with
  per-segment timestamps.
- **Names the speakers.** You're "you" (mic channel); remote voices are separated with a small
  on-device diarization model ([FluidAudio](https://github.com/FluidInference/FluidAudio), ~22 MB,
  downloaded once). Calendar attendees are offered as rename suggestions, and renaming a speaker
  fixes the whole transcript.
- **Summarizes on device** with Apple Intelligence (FoundationModels), following **your**
  editable markdown templates. Long meetings map-reduce through the model; meetings too big for
  it route to your own Claude or Codex account.
- **Drafts notes live.** While a meeting is still recording, Parfait streams a first-pass summary
  from the live transcript so notes appear within seconds — then refines them after the call ends.
- **Everything is editable** — title, notes, transcript, speakers.
- **Calendar-aware.** With Calendar access, **Coming up** shows your agenda, pre-fills titles and
  attendees when you record, and offers one-click join links (Zoom, Meet, Teams, Webex). A menu-bar
  countdown can remind you before the next event.
- **Folders for recurring meetings.** Group standups, 1:1s, and project syncs into folders. Assign
  from the sidebar, drag-and-drop, or **Add to folder** on an upcoming event — future recordings
  with the same calendar title land in the same folder automatically.
- **Ask live, mid-meeting.** A floating card shows the transcript as it happens; one button opens
  your assistant on the call in progress. Parfait exposes the running transcript through a
  `get_live_transcript` MCP tool, so you can ask "what did I miss?" or "what should I ask next?"
  — no pasting, and it rides over full-screen Zoom.
- **Ask about one meeting or all of them.** The **Ask** screen answers in-app (Apple Intelligence)
  or opens Claude / Codex with your meeting library loaded through Parfait's MCP connector — nothing
  is copied in. Once connected, you can skip the app entirely and just ask your assistant anytime.
- **Regenerate and edit notes through MCP.** Claude or Codex can regenerate a meeting's notes against
  a different template, or edit them directly, through the same server.
- **Publish** a beautiful self-contained page (notes + transcript) as a secret gist on your own
  GitHub (`gh`), with a rendered **notes.parfait.to** URL to share — Parfait's own CDN serving
  your gist back rendered, not a raw-file host — or preview/export the HTML locally with no
  dependencies at all.
- **Plain files, no database.** Every meeting is a folder of JSON + Markdown + m4a in
  `~/Library/Application Support/Parfait`. Your data is greppable, backupable, yours.

## The stack is the feature

Parfait has no backend, no accounts, and no API keys. It composes things your Mac already has:

| Need | Provider |
|---|---|
| Meeting detection | Core Audio process objects (mic-in-use by other apps) |
| System-audio capture | Core Audio process taps (macOS 14.4+) |
| Transcription | SpeechAnalyzer / SpeechTranscriber (macOS 26, on device) |
| Speaker separation | FluidAudio CoreML diarization (on device) |
| Summaries, titles | Apple Intelligence FoundationModels (on device) |
| Long meetings, publishing | **Your own** Claude or Codex account via the `claude` / `codex` CLI |
| Ask (per-meeting, cross-meeting, live) | **Apple Intelligence** in-app, or **your own** Claude / Codex (CLI or desktop app) via Parfait's MCP connector |
| Calendar | EventKit (on device) |
| Publish target | **Your own** GitHub via `gh` (secret gist), served back rendered by **notes.parfait.to** (Parfait's own CDN in front of your gist), or a local browser preview / HTML export |

## Requirements

- **macOS 26 (Tahoe)** on Apple Silicon
- **Apple Intelligence enabled** (Settings → Apple Intelligence & Siri) for on-device summaries
  and in-app Ask
- **Optional — Claude:** [Claude Desktop](https://claude.ai/download) or
  [Claude Code](https://claude.com/claude-code) (`claude` CLI, logged in) — for cloud Ask and
  long-meeting summaries, billed to your own plan
- **Optional — Codex:** [Codex](https://chatgpt.com/codex) (`codex` CLI, logged in) — same as
  Claude, through your own account
- **Optional:** [GitHub CLI](https://cli.github.com) (`gh auth login`) — to publish a shareable
  rendered URL as a gist on your own account (without it, you can still preview and export the
  HTML locally)

## Install

```bash
git clone https://github.com/conrad-vanl/parfait.git
cd parfait
make install        # builds, assembles Parfait.app, copies to /Applications
open /Applications/Parfait.app
```

Look for the parfait glass in your menu bar. A first-run onboarding walkthrough covers permissions
and optional setup. On first recording, macOS will ask for **Microphone** and **System Audio
Recording** permission (the latter lives under Privacy & Security → Screen & System Audio
Recording → "System Audio Recording Only").

> **Signing note:** `make install` ad-hoc signs with a stable designated requirement, so TCC
> permissions survive rebuilds. If you have an Apple Development certificate, prefer
> `make install SIGN_ID="Apple Development: you@example.com (TEAMID)"`.

## Connect your assistant to your meeting library

Pick your assistant in **Settings → Intelligence**. For Claude or Codex, add the Parfait MCP
connector once — the app has one-click setup buttons, or run it yourself:

### Claude Code

```bash
claude mcp add parfait -s user -- "/Applications/Parfait.app/Contents/MacOS/Parfait" --mcp
```

### Codex

```bash
codex mcp add parfait -- "/Applications/Parfait.app/Contents/MacOS/Parfait" --mcp
```

Then from any session (or the desktop app with the same server):

> "Search my meetings for when I last discussed hiring, and summarize what was decided."

The MCP server (`Parfait --mcp`) speaks stdio over your on-disk library. Read tools:
`list_meetings`, `search_meetings`, `get_meeting`, `get_transcript`, and `get_live_transcript`
(the meeting in progress). Edit tools: `regenerate_summary`, `update_summary`, and the template
tools (`list_templates`, `get_template`, `create_template`, `update_template`, `rename_template`,
`delete_template`). Nothing leaves your Mac except what the model reads or writes through them.

### Claude Desktop

Claude Desktop reads MCP servers from a config file, not a CLI command. Open (or create)
`~/Library/Application Support/Claude/claude_desktop_config.json` and merge this into the
`mcpServers` object — **don't overwrite the file** if you already have other servers configured:

```json
{
  "mcpServers": {
    "parfait": {
      "command": "/Applications/Parfait.app/Contents/MacOS/Parfait",
      "args": ["--mcp"]
    }
  }
}
```

Restart Claude Desktop after saving. Settings → Intelligence has "Add to Claude Code" and
"Add to Claude Desktop" buttons, plus "Copy JSON" and "Reveal in Finder" for manual setup.

### Codex

Codex stores MCP servers in `~/.codex/config.toml`. Settings → Intelligence has an "Add with
Codex" button, or run the `codex mcp add` command above. Use `$parfait` (not `@`) to attach
the connector in Codex prompts.

## Templates

Notes are shaped by markdown templates you can edit in **Settings → Templates** (or any editor —
they're just files in `~/Library/Application Support/Parfait/Templates/`). Headings guide the
model; prose under a heading tells it what belongs there. Placeholders: `{{title}}`, `{{date}}`,
`{{attendees}}`, `{{duration}}`, `{{app}}`. Ships with **Meeting Notes**, **1-on-1**, and
**Interview**.

## Privacy model

- Audio, transcripts, and notes never leave your Mac by default.
- The only network calls Parfait itself makes: one-time model downloads (Apple speech assets via
  the OS; the diarization model from Hugging Face).
- Anything involving Claude, Codex, or GitHub happens through **your** already-authenticated
  CLIs, at your explicit request (chat, publish, or when a meeting exceeds the on-device model),
  on your own accounts.
- Publishing is always an explicit action. "Secret" gists are unlisted (on your own account,
  deletable) — anyone with the link can view the page; the browser preview and HTML export never
  leave your Mac. Deleting the gist stops new visits, but the rendered link is cached at the
  edge and in browsers, so it can keep serving for up to about a day after deletion.

## Development

```bash
swift build          # debug build
swift test           # 160 unit tests (store, folders, labeling, formatting, templates, MCP, HTML, live transcription, calendar, Claude/Codex deep-links, CLI args)
make app             # assemble dist/Parfait.app
make icon            # regenerate the icon from scripts/MakeIcon.swift
```

The audio/ML paths need live permissions no CI box has; they're covered by the manual checklist
in [docs/TESTING.md](docs/TESTING.md). Architecture and design decisions live in
[docs/superpowers/specs/](docs/superpowers/specs/2026-07-09-parfait-design.md).

```
Sources/Parfait/
  Domain/          Protocols (repositories, services) + use cases (SRP, testable business logic)
  Data/            Repository adapters + service implementations (file, EventKit, audio, AI)
  Presentation/    ViewModels (MVVM) + Views (SwiftUI)
  Audio/           MeetingDetector · MicRecorder · SystemAudioTap · RecordingSession
  Transcription/   Transcriber · Diarizer · SpeakerLabeler
  Intelligence/    AppleSummarizer · ClaudeCLI · CodexCLI · TemplateStore
  Calendar/        CalendarStore · UpcomingMeetings · ConferenceJoiner
  Store/           Domain models · MeetingArchive · folders
  MCP/             stdio MCP server (--mcp)
  Publish/         HTMLExporter · GitHubGist
  App/             DependencyContainer · AppState (coordinator) · ProcessingPipeline
```

## Acknowledgements

- [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache-2.0) for CoreML speaker
  diarization; model weights (CC-BY-4.0) derive from
  [pyannote](https://github.com/pyannote/pyannote-audio) and
  [WeSpeaker](https://github.com/wenet-e2e/wespeaker).
- [Granola](https://granola.ai) for showing how good meeting notes can feel.

## License

[MIT](LICENSE)
