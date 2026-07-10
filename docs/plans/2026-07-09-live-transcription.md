# Live transcription + "Ask Claude live" — design (2026-07-09)

> Status: DESIGN, awaiting Conrad's review before implementation. Item 7 of the
> post-compact fixes batch (see tasks/todo.md).

## What Conrad asked for

> "What would it take to live transcribe meetings as we go in real time? I think
> Apple Intelligence has a live transcription model? ... What I'd like to add is
> a button in the recording UI that takes me to claude that allows me to ask
> questions about the meeting to claude _live_ during the meeting."

And, on mechanism (clarification):

> "I do not want to pass transcript window straight to the claude prompt. Maybe a
> new mcp function `get_live_transcript` ... that pulls the current transcript
> for the meeting in progress?"

So two things: (1) a rolling transcript shown as the meeting happens, and (2) an
"Ask Claude live" button that opens Claude with a prompt telling it to call a new
`get_live_transcript` MCP tool — not embedding the transcript text in the prompt.

## Where we are today

Transcription is **batch / post-recording**: `Transcriber.transcribeFile(at:)`
runs `SpeechAnalyzer.analyzeSequence(from:)` over the finished `.m4a` after
`stopRecording()`, with **no** `.volatileResults` (each result final once).
Diarization (FluidAudio) and the FoundationModels summary also run post-hoc in
`ProcessingPipeline`. Nothing is transcribed while recording.

The live PCM already flows, though: `MicRecorder` installs an `AVAudioEngine`
input tap that hands us buffers in `process(_:)` in real time; `SystemAudioTap`
captures the output side the same way. Both currently only *write* to their
`.m4a`. That's the hook a live transcriber taps into.

`SpeechAnalyzer` / `SpeechTranscriber` (macOS 26, already a dependency) supports
**streaming with volatile (partial) results** on-device — so this is feasible
with the model we already ship; no new framework.

## Why keep the batch pass (yes, it transcribes twice — on purpose)

Conrad asked: since the existing batch path is unchanged, do we transcribe twice,
and could we rely on the live transcriber alone? Decision: **keep both.** They
optimize for different things:

- **Live** (streaming, `.volatileResults`) optimizes for **latency**. Volatile
  results are interim guesses that get revised; even *finalized* streaming
  segments commit with limited look-ahead under a real-time budget, so accuracy
  sits a notch below offline.
- **Batch** (`analyzeSequence` over the finished `.m4a`) optimizes for
  **accuracy**: full audio context, no latency budget → the best the model can
  do, deterministically, over the clean recording.

Beyond raw ASR, the batch pipeline also runs **FluidAudio diarization** for real
speaker attribution; the live pass only has coarse channel-based "You / Others".
And the batch pass over the finished file is **complete and reliable** — the live
pass can drop buffers or gap under load, and the saved record should never
inherit those hiccups.

So the live transcript is a real-time *convenience* (glance + ask Claude live);
the **batch transcript stays the durable, accurate record** that feeds the
summary. The second pass is on-device, runs once after the meeting, and is
exactly what happens today — no regression. If profiling later shows the double
pass hurts, we could revisit promoting live→final + diarize-only, but I wouldn't
start there.

## Architecture (4 pieces)

```
 RecordingSession.start()
   ├─ MicRecorder  ──tap buffers──┐
   │                              ├──▶ LiveTranscriber ──▶ live.json  (meeting folder)
   └─ SystemAudioTap ─tap buffers─┘        (streaming              ▲
                                            SpeechAnalyzer,        │ debounced atomic writes
                                            .volatileResults)      │
                                                                   │
 Recording UI (SidebarRecordingStrip / floating card)             │
   ├─ live transcript view  ◀──────────────────────────────────── │ (in-process, via @Published)
   └─ "Ask Claude live" button ──▶ claude://… "use get_live_transcript"
                                                                   │
 Separate `--mcp` process ──▶ get_live_transcript ──reads────────┘  live.json of the
                                                                     state==.recording meeting
```

### A. `LiveTranscriber` — streaming on-device ASR

New `Sources/Parfait/Transcription/LiveTranscriber.swift`.

- Wraps a streaming `SpeechAnalyzer` + `SpeechTranscriber` configured with
  `.volatileResults` so it emits **partial** hypotheses that firm up into
  **finalized** segments (unlike the batch path). Verify the exact streaming API
  (input `AsyncStream<AnalyzerInput>`, `volatileResults`, finalization) against
  the macOS 26 SDK at implementation time — the batch path is our reference.
- **Audio feed:** add an optional `bufferSink: (@Sendable (AVAudioPCMBuffer) ->
  Void)?` to `MicRecorder` and `SystemAudioTap`, forwarded from
  `RecordingSession`. The sink converts each tap buffer to the analyzer's
  preferred input format (reuse the `AVAudioConverter` pattern already in
  `MicRecorder.writeLocked`) and pushes it into the transcriber's input stream.
- **Two streams, coarse attribution (recommended):** run one transcriber on the
  **mic** (tagged "You" / `isMe`) and one on the **system tap** (tagged the
  meeting / others), and merge finalized segments by timestamp into one rolling
  list. This reuses both capture paths, gives usable who-said-what without
  diarization, and mirrors the shape of the final transcript. *Alternative:* one
  transcriber over a mic+system mix — cheaper (one analyzer) but no attribution.
  **DECIDED (Conrad): two streams**, with the single-mixed-stream kept as a
  fallback only if profiling shows it's too heavy.
- Only **finalized** segments are persisted; the current volatile fragment can be
  surfaced live in the UI (in-process) but is not written to disk, to keep
  `live.json` stable for cross-process reads.

### B. Persistence — `live.json` in the meeting folder

Reuse the existing per-meeting folder (`MeetingArchive.folder(for:)`):

```
<root>/Meetings/<uuid>/
    meeting.json      (state == .recording while live)
    live.json         [TranscriptSegment]  ← NEW, only present while recording
    ...
```

- Store `[TranscriptSegment]` (same type `get_transcript` uses) so
  `get_live_transcript` can format it with the existing
  `TranscriptFormatter.plainText`. Speaker ids map to two synthetic speakers
  ("You" with `isMe = true`, and the meeting/others).
- Written **debounced** (≈ every 1–2 s or on each finalized segment) and
  **atomically** (`.write(…, options: .atomic)`, as the archive already does) so
  the MCP process never sees a torn file.
- Add `MeetingArchive.saveLiveTranscript(_:for:)` / `liveTranscript(for:)` /
  `removeLiveTranscript(for:)`.
- **Cleanup:** delete `live.json` when the final `transcript.json` is written
  (end of `ProcessingPipeline`), so `get_live_transcript` only ever reflects an
  actually-live meeting and never a stale finished one.

### C. `get_live_transcript` MCP tool

Add to `MCPServer.toolDefinitions` + `call(tool:)`.

- **No `id` argument** — there is at most one live meeting. The tool finds it:
  `archive.allMeetings().first { $0.state == .recording }`, then reads that
  meeting's `live.json`.
- **Freshness guard:** to avoid a crash-orphaned `.recording` meeting (one left
  before `finalizeOrphans` runs at next launch) looking "live", require
  `live.json`'s mtime to be recent (e.g. < 60 s). Otherwise report nothing live.
- **Returns:** the formatted rolling transcript with a header noting it is live
  and partial (e.g. "Live transcript of the meeting in progress (may lag a few
  seconds and isn't final)"), or "No meeting is being recorded right now." on
  isError=false.
- Description steers Claude: "Get the transcript of the meeting happening RIGHT
  NOW, as far as it's been transcribed. Use this to answer questions during a
  live meeting."

### D. Recording UI — live view + "Ask Claude live"

DECIDED (Conrad): the live transcript shows in **two** places while recording,
both observing `RecordingSession` directly in-process (no disk round-trip):

- **The floating recording card grows** a scrollable region showing the rolling
  transcript (finalized segments + the current volatile fragment) updating in
  place.
- **The Transcript tab in `MeetingDetailView`** shows it too: while a meeting is
  the one being recorded (`meeting.id == app.recordingMeeting?.id`),
  `TranscriptTab` renders the live rolling transcript instead of the (still-empty)
  saved `transcript.json`; once recording stops and the batch transcript lands,
  it shows that, as it does today.

`RecordingSession` gains `@Published var liveSegments: [TranscriptSegment]` and
`@Published var volatileText: String` that both views observe.
- **"Ask Claude live" button:** reuses the `ClaudeDesktop` / `ClaudeCode` deep
  link. Opens Claude with a prompt like:

  > I'm in a meeting right now, being recorded by Parfait. Get the live transcript and answer my question:
  > `<my question>`.

  Prompt carries **no transcript text** (per Conrad) — Claude pulls it via the
  tool. The "Ask Claude" button opens straight to the prompt and the can continue typing.

### E. Lifecycle wiring

- `RecordingSession.start(...)`: always start `LiveTranscriber` (DECIDED:
  always-on, no Setting toggle) and begin writing `live.json`.
- `RecordingSession.stop()`: stop the transcriber, flush a final `live.json`.
- `ProcessingPipeline`: after `transcript.json` is saved, remove `live.json`.
- `discardRecording()` / `delete`: folder removal already takes `live.json` with
  it.
- Diarization stays **post-hoc** — the accurate final `transcript.json` +
  FoundationModels summary pipeline is unchanged; `live.json` is a real-time
  approximation, never the source of truth.

## Cost, performance, risk

- On-device streaming ASR is what `SpeechAnalyzer` is designed for; the main new
  cost is running **two** transcribers concurrently. Modern Apple Silicon should
  handle it, but if profiling shows it's heavy, fall back to the single mixed
  stream (open question #1). Battery: meaningful only during active meetings.
- Cross-process read/write races on `live.json` → atomic writes close it.
- Volatile-result churn → persist only finalized segments; keep volatile text
  in-process for the UI.
- Streaming API specifics (`volatileResults`, input stream, finalize semantics)
  are the one real unknown — verify against the SDK first, behind a tiny spike,
  before building the UI on top.

## Testing

- Unit: `LiveTranscriber` segment-merge/formatting; `get_live_transcript`
  (fixture: a `.recording` meeting + a `live.json` → formatted output; a stale
  mtime → "nothing live"; no recording → "nothing live"). Extend
  `MCPServerTests`.
- Manual: a real meeting — confirm the live transcript scrolls, the button opens
  Claude, and Claude's `get_live_transcript` returns the in-progress text.

## Decisions (Conrad, 2026-07-09) — all resolved, cleared to build

1. **Attribution vs cost** → two live transcribers, "You" / "Others" (single
   mixed stream kept only as a fallback if it profiles too heavy).
2. **Always-on vs opt-in** → always-on; no Setting toggle.
3. **UI home** → grow the floating card AND show the live transcript in the
   `MeetingDetailView` Transcript tab while recording.
4. **Keep the batch pass?** → yes, keep transcribing twice (see "Why keep the
   batch pass"): live = real-time convenience, batch = durable accurate record +
   diarization.

## Out of scope (later)

- Live diarization / accurate live speaker names.
- Live summary/notes as you go.
- Notifying/streaming to Claude proactively (Claude only reads on demand via the
  tool).
