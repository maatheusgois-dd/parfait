# Manual smoke checklist

The audio/ML paths need live TCC grants and Apple Intelligence, which no CI box
has — so they're verified by hand before a release. `swift test` covers the pure
logic (store, labeling, formatting, templates, MCP, HTML export, CLI args).

## Setup
- [ ] `make install` then launch Parfait from /Applications
- [ ] Parfait glass appears in the menu bar; popover opens

## Recording
- [ ] "Start recording" prompts for mic on first use; level meter moves when you talk
- [ ] Play any audio (YouTube) — first recording prompts for System Audio Recording;
      after granting, restart the recording once (macOS quirk: the first grant applies
      to the *next* tap)
- [ ] Stop & summarize → meeting appears, goes `processing` → `ready`
- [ ] Both `mic.m4a` and `system.m4a` exist in the meeting folder (Share → Show files)

## Detection
- [ ] With "Detect meetings" on: start a Zoom/Meet/FaceTime call → notification appears
- [ ] "Record" on the notification starts the session (source app shows in the header)
- [ ] With "Start recording without asking" on: recording starts by itself, and stops
      ~8s after the call app releases the mic

## Pipeline quality
- [ ] Transcript has your words under your name and remote audio under Speaker 1..N
- [ ] With "Identify individual speakers" on and a 2+ person call, remote speakers split
- [ ] Rename a speaker → every segment updates; calendar attendees offered as suggestions
- [ ] Summary follows the selected template's headings; title becomes specific
- [ ] On a Mac without Apple Intelligence (or with a >30 min meeting): summary badge
      says Claude instead of On-device

## Editing
- [ ] Title, summary (Edit), and transcript (Edit as text) all save and survive relaunch
- [ ] Switching template + Regenerate rewrites the notes

## Chat
- [ ] Meeting → Chat answers from the transcript (On-device badge for short meetings)
- [ ] "Ask your meetings" answers questions that require searching older meetings
      (Claude badge; needs `claude` logged in)

## Publish
- [ ] Share → Publish to secret Gist returns a URL that renders the styled page in a browser (needs gh)
- [ ] URL lands on the clipboard; "Open published page" works after reselecting the meeting
- [ ] Share → Preview in browser opens the styled page locally (nothing uploaded)
- [ ] Share → Export HTML… writes a self-contained file that opens in a browser
- [ ] With gh not installed, the Gist item is disabled; preview + export still work

## MCP
- [ ] `claude mcp add parfait -s user -- "/Applications/Parfait.app/Contents/MacOS/Parfait" --mcp`
- [ ] In any `claude` session: "list my recent meetings" hits mcp__parfait__list_meetings

## Resilience
- [ ] Quit the app mid-recording, relaunch → orphaned meeting finalizes into a normal one
- [ ] Deny mic but grant system audio → recording still works, notice explains the gap
